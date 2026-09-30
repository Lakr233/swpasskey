// macOS menu bar status item for swpasskeyd: a key icon whose menu shows the
// credential count, opens the Keys window (installed credentials, delete)
// and the Preferences window (launch at login via SMAppService, log level,
// daemon facts), and quits the daemon.
//
// Dock: the app is an accessory (no Dock icon) until its status menu is open
// or one of its windows is on screen; then it becomes a regular app so the
// windows show up in the Dock and Cmd-Tab. It drops back when both are gone.
// A short welcome window at launch says where the app lives, unless it was
// started by its own login item or the user turned the welcome off.
//
// Everything here runs on the main thread inside the AppKit loop that
// AlertPresence::run_main_loop() drives. Store reads go through
// CredentialStore's own mutex; deletes go through Authenticator::ctl_delete
// via MenuBarDeps::delete_key, which serialises against CTAP traffic.
#if defined(__APPLE__)

#include "swpasskey/ui/menubar.hpp"

#include "swpasskey/log/log.hpp"
#include "swpasskey/ui/keys_model.hpp"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr const char* kLogLevelDefault = "SWPKLogLevel";
constexpr const char* kHideWelcomeDefault = "SWPKHideWelcome";
constexpr const char* kAgentLabel = "com.tangzixiang.swpasskey.daemon";
NSString* const kAgentPlist = @"com.tangzixiang.swpasskey.daemon.plist";

// launchd sets XPC_SERVICE_NAME to the job label for the login item.
bool launched_by_login_item() {
  const char* name = std::getenv("XPC_SERVICE_NAME");
  return name != nullptr && std::strcmp(name, kAgentLabel) == 0;
}

NSMenuItem* menu_item(NSString* title, SEL action, NSString* key, id target = nil) {
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
  item.target = target;
  return item;
}

NSString* ns(const std::string& s) {
  NSString* out = [NSString stringWithUTF8String:s.c_str()];
  return out != nil ? out : @"?";
}

std::vector<std::uint8_t> unhex(const std::string& h) {
  std::vector<std::uint8_t> out;
  auto nib = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  if (h.size() % 2 != 0) return out;
  for (std::size_t i = 0; i + 1 < h.size(); i += 2) {
    const int a = nib(h[i]), b = nib(h[i + 1]);
    if (a < 0 || b < 0) return {};
    out.push_back(static_cast<std::uint8_t>(a * 16 + b));
  }
  return out;
}

const char* level_name(swpk::log::Level l) {
  switch (l) {
    case swpk::log::Level::Error: return "error";
    case swpk::log::Level::Warn: return "warn";
    case swpk::log::Level::Info: return "info";
    case swpk::log::Level::Debug: return "debug";
  }
  return "info";
}

bool level_from_name(const std::string& n, swpk::log::Level& out) {
  if (n == "error") { out = swpk::log::Level::Error; return true; }
  if (n == "warn") { out = swpk::log::Level::Warn; return true; }
  if (n == "info") { out = swpk::log::Level::Info; return true; }
  if (n == "debug") { out = swpk::log::Level::Debug; return true; }
  return false;
}

void activate_app() {
  if (@available(macOS 14.0, *)) {
    [NSApp activate];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
  }
}

NSTextField* label(NSString* text, NSRect frame, bool bold = false) {
  NSTextField* f = [[NSTextField alloc] initWithFrame:frame];
  f.stringValue = text;
  f.editable = NO;
  f.bordered = NO;
  f.drawsBackground = NO;
  f.selectable = YES;
  f.lineBreakMode = NSLineBreakByTruncatingMiddle;
  if (bold) {
    f.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
  }
  return f;
}

}  // namespace

@interface SWPKMenuController
    : NSObject <NSApplicationDelegate, NSMenuDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
- (instancetype)initWithDeps:(swpk::ui::MenuBarDeps)deps;
- (void)teardown;
@end

@implementation SWPKMenuController {
  swpk::ui::MenuBarDeps deps_;
  std::vector<swpk::ui::KeyRow> rows_;
  NSStatusItem* item_;
  NSMenu* menu_;
  NSMenuItem* summaryItem_;
  NSWindow* keysWindow_;
  NSTableView* table_;
  NSButton* deleteButton_;
  NSTextField* keysStatus_;
  NSWindow* prefsWindow_;
  NSButton* loginCheckbox_;
  NSTextField* loginNote_;
  NSPopUpButton* levelPopup_;
  NSButton* pinButton_;
  NSTextField* pinStatus_;
  NSWindow* welcomeWindow_;
  NSButton* welcomeHide_;
  BOOL pinBusy_;
  BOOL menuOpen_;
  BOOL tornDown_;
}

- (instancetype)initWithDeps:(swpk::ui::MenuBarDeps)deps {
  self = [super init];
  if (self == nil) return nil;
  deps_ = std::move(deps);
  [self applyLogLevelPreference];

  item_ = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
  NSImage* icon = [NSImage imageWithSystemSymbolName:@"key.fill" accessibilityDescription:@"swpasskey"];
  if (icon != nil) {
    [icon setTemplate:YES];
    item_.button.image = icon;
  } else {
    item_.button.title = @"\U0001F511";
  }
  item_.button.toolTip = @"swpasskey software authenticator";

  menu_ = [[NSMenu alloc] initWithTitle:@"swpasskey"];
  menu_.delegate = self;
  NSMenuItem* title = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"swpasskey %@", ns(deps_.version)]
                                                 action:nil
                                          keyEquivalent:@""];
  title.enabled = NO;
  [menu_ addItem:title];
  summaryItem_ = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
  summaryItem_.enabled = NO;
  [menu_ addItem:summaryItem_];
  [menu_ addItem:[NSMenuItem separatorItem]];
  NSMenuItem* keys = [[NSMenuItem alloc] initWithTitle:@"Keys…" action:@selector(showKeys:) keyEquivalent:@"k"];
  keys.target = self;
  [menu_ addItem:keys];
  NSMenuItem* prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences…" action:@selector(showPreferences:) keyEquivalent:@","];
  prefs.target = self;
  [menu_ addItem:prefs];
  [menu_ addItem:[NSMenuItem separatorItem]];
  NSMenuItem* quit = [[NSMenuItem alloc] initWithTitle:@"Quit swpasskey" action:@selector(quit:) keyEquivalent:@"q"];
  quit.target = self;
  [menu_ addItem:quit];
  item_.menu = menu_;
  [self refreshSummary];
  [self installMainMenu];
  NSApp.delegate = self;
  // Queued until the presence loop runs NSApp (it sets the accessory policy
  // first), so the welcome's Dock switch is not overwritten.
  if (!launched_by_login_item() &&
      ![[NSUserDefaults standardUserDefaults] boolForKey:@(kHideWelcomeDefault)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!tornDown_) [self showWelcome];
    });
  }
  swpk::log::info("menubar_ready");
  return self;
}

- (void)teardown {
  tornDown_ = YES;
  if (item_ != nil) {
    [[NSStatusBar systemStatusBar] removeStatusItem:item_];
    item_ = nil;
  }
  if (NSApp.delegate == self) {
    NSApp.delegate = nil;
  }
  [welcomeWindow_ close];
  [keysWindow_ close];
  [prefsWindow_ close];
}

// Only visible while the app is regular (a window is open): Quit, the edit
// commands the PIN fields need, and Close / Minimize for the windows.
- (void)installMainMenu {
  NSMenu* bar = [[NSMenu alloc] init];
  NSMenu* app = [[NSMenu alloc] initWithTitle:@"swpasskey"];
  [app addItem:menu_item(@"Preferences…", @selector(showPreferences:), @",", self)];
  [app addItem:[NSMenuItem separatorItem]];
  [app addItem:menu_item(@"Quit swpasskey", @selector(quit:), @"q", self)];
  NSMenu* edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  [edit addItem:menu_item(@"Cut", @selector(cut:), @"x")];
  [edit addItem:menu_item(@"Copy", @selector(copy:), @"c")];
  [edit addItem:menu_item(@"Paste", @selector(paste:), @"v")];
  [edit addItem:menu_item(@"Select All", @selector(selectAll:), @"a")];
  NSMenu* window = [[NSMenu alloc] initWithTitle:@"Window"];
  [window addItem:menu_item(@"Close", @selector(performClose:), @"w")];
  [window addItem:menu_item(@"Minimize", @selector(performMiniaturize:), @"m")];
  [window addItem:[NSMenuItem separatorItem]];
  [window addItem:menu_item(@"Keys", @selector(showKeys:), @"k", self)];
  for (NSMenu* sub in @[ app, edit, window ]) {
    NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle:sub.title action:nil keyEquivalent:@""];
    holder.submenu = sub;
    [bar addItem:holder];
  }
  NSApp.mainMenu = bar;
  NSApp.windowsMenu = window;
}

#pragma mark - Dock

- (void)updateDockPolicy {
  if (tornDown_) return;
  const BOOL visible = menuOpen_ || welcomeWindow_.visible || keysWindow_.visible || prefsWindow_.visible ||
                       keysWindow_.miniaturized || prefsWindow_.miniaturized;
  const NSApplicationActivationPolicy want =
      visible ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory;
  if (NSApp.activationPolicy != want) {
    [NSApp setActivationPolicy:want];
  }
}

// Deferred one turn: the window being closed is still visible here, and a
// menu action (Keys…, Preferences…) runs after menuDidClose:.
- (void)scheduleDockUpdate {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateDockPolicy];
  });
}

- (void)present:(NSWindow*)window {
  [window makeKeyAndOrderFront:nil];
  [self updateDockPolicy];
  activate_app();
}

- (void)windowWillClose:(NSNotification*)notification {
  [self scheduleDockUpdate];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  // Dock › Quit or logout: stop the daemon loop, which stops NSApp and lets
  // main() shut down cleanly. Later (not Cancel) so logout is not vetoed;
  // the process exits before a reply is needed.
  [self quit:sender];
  return NSTerminateLater;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag {
  if (!flag) [self showKeys:sender];
  return NO;
}

#pragma mark - welcome

- (void)showWelcome {
  if (welcomeWindow_ == nil) {
    [self buildWelcomeWindow];
  }
  [self present:welcomeWindow_];
}

- (void)buildWelcomeWindow {
  const CGFloat W = 420, H = 150;
  welcomeWindow_ = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                               styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
  welcomeWindow_.title = @"swpasskey";
  welcomeWindow_.releasedWhenClosed = NO;
  welcomeWindow_.delegate = self;
  [welcomeWindow_ center];
  NSView* v = welcomeWindow_.contentView;

  NSImageView* icon = [NSImageView imageViewWithImage:[NSApp applicationIconImage]];
  icon.frame = NSMakeRect(20, H - 84, 64, 64);
  [v addSubview:icon];
  NSTextField* title = label(@"swpasskey is running", NSMakeRect(100, H - 44, W - 120, 22), true);
  [v addSubview:title];
  NSTextField* body = [NSTextField wrappingLabelWithString:
      @"Find it in the menu bar under the key icon. Browsers can now use it as a security key."];
  body.frame = NSMakeRect(100, H - 90, W - 120, 40);
  body.textColor = [NSColor secondaryLabelColor];
  [v addSubview:body];

  welcomeHide_ = [NSButton checkboxWithTitle:@"Don’t show this again" target:nil action:nil];
  welcomeHide_.frame = NSMakeRect(100, 18, 200, 20);
  [v addSubview:welcomeHide_];
  NSButton* ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(dismissWelcome:)];
  ok.frame = NSMakeRect(W - 100, 12, 80, 32);
  ok.keyEquivalent = @"\r";
  [v addSubview:ok];
}

- (void)dismissWelcome:(id)sender {
  if (welcomeHide_.state == NSControlStateValueOn) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@(kHideWelcomeDefault)];
  }
  [welcomeWindow_ close];
}

#pragma mark - menu

- (void)menuNeedsUpdate:(NSMenu*)menu {
  [self refreshSummary];
}

- (void)menuWillOpen:(NSMenu*)menu {
  menuOpen_ = YES;
  [self updateDockPolicy];
}

- (void)menuDidClose:(NSMenu*)menu {
  menuOpen_ = NO;
  [self scheduleDockUpdate];
}

- (void)refreshSummary {
  const std::size_t n = deps_.store != nullptr ? deps_.store->size() : 0;
  summaryItem_.title = ns(swpk::ui::keys_summary(n, deps_.key_backend));
}

- (void)quit:(id)sender {
  swpk::log::info("menubar_quit");
  if (deps_.quit) {
    deps_.quit();
  }
}

#pragma mark - keys window

- (void)showKeys:(id)sender {
  if (keysWindow_ == nil) {
    [self buildKeysWindow];
  }
  [self reloadKeys];
  [self present:keysWindow_];
}

- (void)buildKeysWindow {
  NSRect frame = NSMakeRect(0, 0, 720, 380);
  keysWindow_ = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  keysWindow_.title = @"swpasskey Keys";
  keysWindow_.releasedWhenClosed = NO;
  keysWindow_.minSize = NSMakeSize(520, 240);
  keysWindow_.delegate = self;
  [keysWindow_ center];
  NSView* content = keysWindow_.contentView;

  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 52, frame.size.width - 32, frame.size.height - 68)];
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  table_ = [[NSTableView alloc] initWithFrame:scroll.bounds];
  table_.dataSource = self;
  table_.delegate = self;
  table_.allowsMultipleSelection = NO;
  table_.usesAlternatingRowBackgroundColors = YES;
  table_.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  struct Col { NSString* id; NSString* title; CGFloat width; };
  const Col cols[] = {
      {@"rp", @"Site", 180}, {@"user", @"User", 150}, {@"backend", @"Key storage", 110},
      {@"created", @"Created", 110}, {@"used", @"Last used", 110}, {@"count", @"Uses", 50},
  };
  for (const auto& c : cols) {
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:c.id];
    col.title = c.title;
    col.width = c.width;
    col.minWidth = 40;
    [table_ addTableColumn:col];
  }
  scroll.documentView = table_;
  [content addSubview:scroll];

  keysStatus_ = label(@"", NSMakeRect(16, 18, frame.size.width - 260, 20));
  keysStatus_.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  keysStatus_.textColor = [NSColor secondaryLabelColor];
  [content addSubview:keysStatus_];

  NSButton* refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(reloadKeys)];
  refresh.frame = NSMakeRect(frame.size.width - 226, 12, 100, 32);
  refresh.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  [content addSubview:refresh];

  deleteButton_ = [NSButton buttonWithTitle:@"Delete…" target:self action:@selector(deleteSelected:)];
  deleteButton_.frame = NSMakeRect(frame.size.width - 116, 12, 100, 32);
  deleteButton_.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  deleteButton_.enabled = NO;
  [content addSubview:deleteButton_];
}

- (void)reloadKeys {
  rows_ = deps_.store != nullptr ? swpk::ui::key_rows(*deps_.store) : std::vector<swpk::ui::KeyRow>{};
  [table_ reloadData];
  keysStatus_.stringValue = ns(swpk::ui::keys_summary(rows_.size(), deps_.key_backend));
  deleteButton_.enabled = table_.selectedRow >= 0;
  [self refreshSummary];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
  return static_cast<NSInteger>(rows_.size());
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
  if (row < 0 || static_cast<std::size_t>(row) >= rows_.size()) return @"";
  const auto& r = rows_[static_cast<std::size_t>(row)];
  NSString* ident = column.identifier;
  if ([ident isEqualToString:@"rp"]) {
    return r.rp_name.empty() || r.rp_name == r.rp_id ? ns(r.rp_id) : [NSString stringWithFormat:@"%@ (%@)", ns(r.rp_id), ns(r.rp_name)];
  }
  if ([ident isEqualToString:@"user"]) {
    if (r.u2f) return @"(U2F registration)";
    if (!r.user_display.empty() && r.user_display != r.user_name) {
      return [NSString stringWithFormat:@"%@ (%@)", ns(r.user_name), ns(r.user_display)];
    }
    return ns(r.user_name);
  }
  if ([ident isEqualToString:@"backend"]) return ns(r.backend);
  if ([ident isEqualToString:@"created"]) return ns(swpk::ui::format_unix_time(r.created_unix));
  if ([ident isEqualToString:@"used"]) {
    const auto s = swpk::ui::format_unix_time(r.last_used_unix);
    return s.empty() ? @"never" : ns(s);
  }
  if ([ident isEqualToString:@"count"]) return [NSString stringWithFormat:@"%u", r.sign_count];
  return @"";
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
  deleteButton_.enabled = table_.selectedRow >= 0;
}

- (void)deleteSelected:(id)sender {
  const NSInteger sel = table_.selectedRow;
  if (sel < 0 || static_cast<std::size_t>(sel) >= rows_.size()) return;
  const swpk::ui::KeyRow row = rows_[static_cast<std::size_t>(sel)];
  NSAlert* alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = [NSString stringWithFormat:@"Delete the passkey for %@?", ns(row.rp_id)];
  alert.informativeText = [NSString stringWithFormat:
      @"User: %@\nThe site will no longer accept this key. This cannot be undone.",
      row.u2f ? @"U2F registration" : ns(row.user_name)];
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:keysWindow_ completionHandler:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn) return;
    [self deleteCredential:row];
  }];
}

- (void)deleteCredential:(const swpk::ui::KeyRow&)row {
  const auto id = unhex(row.cred_id_hex);
  if (!deps_.delete_key || id.size() != 32) {
    return;
  }
  auto r = deps_.delete_key(id);
  if (!r) {
    NSAlert* err = [[NSAlert alloc] init];
    err.alertStyle = NSAlertStyleCritical;
    err.messageText = @"Could not delete the key";
    err.informativeText = [NSString stringWithFormat:@"CTAP status 0x%02x", static_cast<unsigned>(r.error())];
    [err beginSheetModalForWindow:keysWindow_ completionHandler:nil];
    swpk::log::warn("menubar_delete_failed", {{"cred_id", row.cred_id_hex.substr(0, 16)}});
  } else {
    swpk::log::warn("menubar_delete", {{"cred_id", row.cred_id_hex.substr(0, 16)}, {"rp", row.rp_id}});
  }
  [self reloadKeys];
}

#pragma mark - preferences window

- (void)showPreferences:(id)sender {
  if (prefsWindow_ == nil) {
    [self buildPreferencesWindow];
  }
  [self refreshLoginState];
  [self refreshPinState];
  [self present:prefsWindow_];
}

- (void)buildPreferencesWindow {
  const CGFloat W = 480, H = 420;
  prefsWindow_ = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
  prefsWindow_.title = @"swpasskey Preferences";
  prefsWindow_.releasedWhenClosed = NO;
  prefsWindow_.delegate = self;
  [prefsWindow_ center];
  NSView* v = prefsWindow_.contentView;
  CGFloat y = H - 44;

  loginCheckbox_ = [NSButton checkboxWithTitle:@"Launch swpasskey at login" target:self action:@selector(toggleLogin:)];
  loginCheckbox_.frame = NSMakeRect(20, y, W - 40, 20);
  [v addSubview:loginCheckbox_];
  y -= 20;
  loginNote_ = label(@"", NSMakeRect(38, y, W - 58, 18));
  loginNote_.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
  loginNote_.textColor = [NSColor secondaryLabelColor];
  [v addSubview:loginNote_];
  y -= 36;

  [v addSubview:label(@"Log level:", NSMakeRect(20, y + 2, 90, 20))];
  levelPopup_ = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, y - 2, 140, 26) pullsDown:NO];
  [levelPopup_ addItemsWithTitles:@[ @"error", @"warn", @"info", @"debug" ]];
  [levelPopup_ selectItemWithTitle:@(level_name(swpk::log::level()))];
  levelPopup_.target = self;
  levelPopup_.action = @selector(changeLogLevel:);
  [v addSubview:levelPopup_];
  y -= 22;
  NSTextField* levelNote = label(@"Applies now and at the next launch (JSON lines on stderr).", NSMakeRect(20, y, W - 40, 18));
  levelNote.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
  levelNote.textColor = [NSColor secondaryLabelColor];
  [v addSubview:levelNote];
  y -= 34;

  [v addSubview:label(@"Security key PIN", NSMakeRect(20, y, 240, 20), true)];
  pinButton_ = [NSButton buttonWithTitle:@"Set PIN…" target:self action:@selector(setPin:)];
  pinButton_.frame = NSMakeRect(W - 150, y - 5, 130, 30);
  [v addSubview:pinButton_];
  y -= 26;
  pinStatus_ = label(@"", NSMakeRect(20, y, W - 40, 20));
  [v addSubview:pinStatus_];
  y -= 24;
  NSTextField* pinNote = label(@"Used by sites that require PIN verification to sign in.",
                              NSMakeRect(20, y, W - 40, 20));
  pinNote.textColor = [NSColor secondaryLabelColor];
  [v addSubview:pinNote];
  y -= 40;

  NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(20, y, W - 40, 1)];
  sep.boxType = NSBoxSeparator;
  [v addSubview:sep];
  y -= 28;

  struct Fact { NSString* k; std::string v; };
  const Fact facts[] = {
      {@"Version", deps_.version},
      {@"Key storage", deps_.key_backend},
      {@"Serial", deps_.serial},
      {@"Store", deps_.store_path},
      {@"Control socket", deps_.ctl_socket},
  };
  for (const auto& f : facts) {
    NSTextField* k = label(f.k, NSMakeRect(20, y, 110, 18), true);
    k.alignment = NSTextAlignmentRight;
    [v addSubview:k];
    [v addSubview:label(ns(f.v), NSMakeRect(140, y, W - 160, 18))];
    y -= 24;
  }
}

- (void)refreshPinState {
  if (pinBusy_) return;
  const bool configured = deps_.store != nullptr && deps_.store->pin().hash.has_value();
  pinStatus_.stringValue = configured ? @"PIN is configured." : @"No PIN set. Set one before signing in with a passkey.";
  pinButton_.title = configured ? @"Set new PIN…" : @"Set PIN…";
  pinButton_.enabled = static_cast<bool>(deps_.control_request);
}

- (void)setPin:(id)sender {
  if (pinBusy_ || !deps_.control_request) return;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Set your security key PIN";
  alert.informativeText = @"Choose at least 4 characters (up to 63 UTF-8 bytes). You’ll use this PIN when signing in. Existing passkeys are kept.";
  [alert addButtonWithTitle:@"Set PIN"];
  [alert addButtonWithTitle:@"Cancel"];
  NSView* form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 110)];
  [form addSubview:label(@"New PIN", NSMakeRect(0, 86, 340, 20))];
  NSSecureTextField* pin = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 60, 340, 24)];
  pin.accessibilityLabel = @"New PIN";
  [form addSubview:pin];
  [form addSubview:label(@"Repeat PIN", NSMakeRect(0, 30, 340, 20))];
  NSSecureTextField* repeat = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 4, 340, 24)];
  repeat.accessibilityLabel = @"Repeat PIN";
  [form addSubview:repeat];
  pin.nextKeyView = repeat;
  alert.accessoryView = form;
  alert.window.initialFirstResponder = pin;
  [alert beginSheetModalForWindow:prefsWindow_ completionHandler:^(NSModalResponse response) {
    NSString* value = pin.stringValue;
    const BOOL matches = [value isEqualToString:repeat.stringValue];
    pin.stringValue = @"";
    repeat.stringValue = @"";
    if (response != NSAlertFirstButtonReturn || tornDown_) return;
    const NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    const NSUInteger characters = [value lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4;
    if (!matches || characters < 4 || bytes > 63 ||
        [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) {
      pinStatus_.stringValue = !matches ? @"PINs did not match. Try again." : @"Use at least 4 characters and at most 63 UTF-8 bytes.";
      return;
    }
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"op": @"set-pin", @"pin": value} options:0 error:nil];
    if (data == nil) return;
    const std::string request(static_cast<const char*>(data.bytes), data.length);
    const auto send = deps_.control_request;
    pinBusy_ = YES;
    pinButton_.enabled = NO;
    pinStatus_.stringValue = @"Approve the PIN change in the swpasskey prompt…";
    // The server waits for an AppKit presence prompt: never block the main queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      auto result = send(request);
      BOOL ok = NO;
      if (result) {
        NSData* reply = [NSData dataWithBytes:result->data() length:result->size()];
        id json = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
        ok = [json isKindOfClass:[NSDictionary class]] && [json[@"ok"] isEqual:@YES];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (tornDown_) return;
        pinBusy_ = NO;
        [self refreshPinState];
        pinStatus_.stringValue = ok ? @"PIN saved. Retry signing in to your site." : @"PIN was not saved. Retry and approve the prompt.";
      });
    });
  }];
}

- (void)refreshLoginState {
  if (@available(macOS 13.0, *)) {
    SMAppService* svc = [SMAppService agentServiceWithPlistName:kAgentPlist];
    const char* bundle_path = [[[NSBundle mainBundle] bundlePath] UTF8String];
    swpk::log::debug("menubar_login_item_status",
                     {{"status", std::to_string(static_cast<long>(svc.status))},
                      {"bundle", bundle_path != nullptr ? bundle_path : "?"}});
    switch (svc.status) {
      case SMAppServiceStatusEnabled:
        loginCheckbox_.state = NSControlStateValueOn;
        loginCheckbox_.enabled = YES;
        loginNote_.stringValue = @"Registered as a login item (launchd agent).";
        break;
      case SMAppServiceStatusRequiresApproval:
        loginCheckbox_.state = NSControlStateValueOn;
        loginCheckbox_.enabled = YES;
        loginNote_.stringValue = @"Waiting for approval in System Settings › General › Login Items.";
        break;
      case SMAppServiceStatusNotFound:
        // launchd has never seen the agent; registering is still allowed and
        // reports the real error if the bundle really lacks the plist.
        loginCheckbox_.state = NSControlStateValueOff;
        loginCheckbox_.enabled = YES;
        loginNote_.stringValue = @"Starts the daemon in your session at login.";
        break;
      case SMAppServiceStatusNotRegistered:
      default:
        loginCheckbox_.state = NSControlStateValueOff;
        loginCheckbox_.enabled = YES;
        loginNote_.stringValue = @"Starts the daemon in your session at login.";
        break;
    }
  } else {
    loginCheckbox_.state = NSControlStateValueOff;
    loginCheckbox_.enabled = NO;
    loginNote_.stringValue = @"Needs macOS 13 or later.";
  }
}

- (void)toggleLogin:(id)sender {
  if (@available(macOS 13.0, *)) {
    SMAppService* svc = [SMAppService agentServiceWithPlistName:kAgentPlist];
    NSError* err = nil;
    BOOL ok;
    if (loginCheckbox_.state == NSControlStateValueOn) {
      ok = [svc registerAndReturnError:&err];
      swpk::log::info("menubar_login_item", {{"action", "register"}, {"ok", ok ? "true" : "false"}});
    } else {
      ok = [svc unregisterAndReturnError:&err];
      swpk::log::info("menubar_login_item", {{"action", "unregister"}, {"ok", ok ? "true" : "false"}});
    }
    if (!ok) {
      NSAlert* a = [[NSAlert alloc] init];
      a.alertStyle = NSAlertStyleWarning;
      a.messageText = @"Could not change the login item";
      a.informativeText = err != nil ? err.localizedDescription : @"Unknown error";
      [a beginSheetModalForWindow:prefsWindow_ completionHandler:nil];
    }
  }
  [self refreshLoginState];
}

- (void)changeLogLevel:(id)sender {
  const std::string name = [levelPopup_.titleOfSelectedItem UTF8String];
  swpk::log::Level lvl;
  if (!level_from_name(name, lvl)) return;
  swpk::log::set_level(lvl);
  [[NSUserDefaults standardUserDefaults] setObject:ns(name) forKey:@(kLogLevelDefault)];
  swpk::log::info("menubar_log_level", {{"level", name}});
}

- (void)applyLogLevelPreference {
  NSString* saved = [[NSUserDefaults standardUserDefaults] stringForKey:@(kLogLevelDefault)];
  if (saved == nil) return;
  swpk::log::Level lvl;
  if (level_from_name([saved UTF8String], lvl)) {
    swpk::log::set_level(lvl);
  }
}

@end

namespace swpk::ui {
namespace {

class MacMenuBar final : public MenuBar {
public:
  explicit MacMenuBar(SWPKMenuController* c) : ctrl_(c) {}
  ~MacMenuBar() override {
    @autoreleasepool {
      [ctrl_ teardown];
      ctrl_ = nil;
    }
  }

private:
  SWPKMenuController* ctrl_;
};

}  // namespace

std::unique_ptr<MenuBar> make_menu_bar(MenuBarDeps deps) {
  @autoreleasepool {
    if (![NSThread isMainThread]) {
      log::warn("menubar_not_main_thread");
      return nullptr;
    }
    [NSApplication sharedApplication];  // idempotent; the presence loop configures the policy
    SWPKMenuController* c = [[SWPKMenuController alloc] initWithDeps:std::move(deps)];
    if (c == nil) {
      return nullptr;
    }
    return std::make_unique<MacMenuBar>(c);
  }
}

}  // namespace swpk::ui

#endif  // __APPLE__
