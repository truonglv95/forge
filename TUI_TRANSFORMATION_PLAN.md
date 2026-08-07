# Kế hoạch Transform Forge CLI thành Modern TUI

## 🎯 Mục tiêu tổng quát

Biến Forge CLI từ một công cụ dòng lệnh cơ bản thành một **Terminal User Interface (TUI) hiện đại, thông minh** với trải nghiệm người dùng vượt trội, cạnh tranh với các công cụ như `lazygit`, `htop`, `bottom`, hay `k9s`.

---

## 📊 Đánh giá hiện trạng

### ✅ Điểm mạnh hiện có
1. **Đã có TUI base**: `agent_tui` module đã tồn tại với:
   - Terminal handling (raw mode, bracketed paste, mouse support)
   - Frame buffer rendering
   - Chat interface với AI agent
   - Vim mode support
   - Tab system (multi-tab conversations)
   - Explorer panel
   - Timeline view

2. **Kiến trúc Zig vững chắc**: Build system rõ ràng, package structure tốt

3. **AI integration sâu**: Đã có workflow AI hoàn chỉnh từ context -> proposal -> diff -> apply

### ❌ Điểm yếu cần cải thiện
1. **Giao diện thô sơ**: Rendering còn basic, chưa có component library phong phú
2. **Thiếu responsive layout**: Chưa adaptive với terminal size thay đổi
3. **Color scheme đơn giản**: Chưa có theme system linh hoạt
4. **Keyboard shortcuts chưa tối ưu**: Chưa có command palette, fuzzy finder
5. **Thiếu real-time feedback**: Progress indicators, spinners, animations còn hạn chế
6. **Error handling UX**: Hiển thị lỗi chưa thân thiện
7. **Không có help system inline**: Người dùng phải nhớ commands
8. **Session management cơ bản**: Chưa có persistent sessions, history search tốt

---

## 🏗️ Kiến trúc TUI mới

```
┌─────────────────────────────────────────────────────────────────┐
│  FORGE TUI Architecture                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Presentation Layer                     │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │   │
│  │  │   Layout    │  │   Theme     │  │   Animation     │   │   │
│  │  │   Engine    │  │   System    │  │   Engine        │   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │   │
│  │  ┌─────────────────────────────────────────────────────┐  │   │
│  │  │           Component Library (Widgets)                │  │   │
│  │  │  [StatusBar] [ProgressBar] [Table] [Tree] [Modal]   │  │   │
│  │  │  [Input] [List] [Tabs] [Panel] [HelpOverlay]        │  │   │
│  │  └─────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              ▲                                   │
│                              │ render()                          │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   Application Layer                       │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │   │
│  │  │   State     │  │   Command   │  │   Event         │   │   │
│  │  │   Manager   │  │   Handler   │  │   Bus           │   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │   │
│  │  ┌─────────────────────────────────────────────────────┐  │   │
│  │  │              Input Handler & Keybindings             │  │   │
│  │  │         (Vim/Emacs modes, Fuzzy Finder)              │  │   │
│  │  └─────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              ▲                                   │
│                              │ dispatch()                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Business Logic Layer                   │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │   │
│  │  │  Workspace  │  │  AI Agent   │  │   Task          │   │   │
│  │  │  Service    │  │  Service    │  │   Runner        │   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │   │
│  │  │   LSP       │  │   Git       │  │   Terminal      │   │   │
│  │  │  Client     │  │  Integration│  │   Embed         │   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              ▲                                   │
│                              │ call()                            │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                      Core Services                        │   │
│  │     forge-core | forge-kernel | forge-workspace          │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📋 Kế hoạch triển khai chi tiết

### **Phase 1: Foundation & Core Infrastructure** (2-3 tuần)

#### 1.1. Cải thiện Terminal Abstraction
**File target:** `packages/renderer/src/terminal.zig` (mới)

```zig
// Features cần thêm:
- [ ] Multi-platform terminal detection (kitty, alacritty, iterm2, wezterm)
- [ ] True color support detection
- [ ] Unicode width calculation (for CJK characters)
- [ ] Terminal capability querying (via terminfo or xtgettcap)
- [ ] Graceful degradation khi terminal không support features
```

**Công việc cụ thể:**
- Tạo module `terminal.zig` mới với abstraction layer dày hơn
- Implement terminal capability detection
- Thêm support cho Kitty graphics protocol (cho images/charts)
- Cải thiện mouse scrolling với momentum

#### 1.2. Layout Engine
**File target:** `packages/renderer/src/layout.zig` (enhance)

```zig
// Layout types cần implement:
- [ ] Flexbox-like layout (row/column với flex-grow/shrink)
- [ ] Grid layout (responsive columns)
- [ ] Constraint-based layout (Cassowary algorithm)
- [ ] Auto-scrolling containers
- [ ] Split panes với resizeable dividers
```

**Công việc cụ thể:**
- Refactor layout engine hiện tại thành constraint-based system
- Thêm horizontal/vertical split panels với draggable borders
- Implement responsive design: tự động adjust khi terminal resize
- Add min/max constraints cho components

#### 1.3. Theme System
**File target:** `packages/renderer/src/theme.zig` (enhance)

```zig
// Theme features:
- [ ] Built-in themes: Dark, Light, Catppuccin, Dracula, Nord, Gruvbox
- [ ] Custom theme từ config file (forge.toml)
- [ ] Semantic colors (info, warning, error, success)
- [ ] Syntax highlighting themes tích hợp
- [ ] Dynamic theme switching (Ctrl+T)
```

**Công việc cụ thể:**
- Định nghĩa theme structure với semantic color tokens
- Tích hợp 5-7 popular themes làm defaults
- Đọc custom theme từ `forge.toml`
- Implement hot-reload theme khi config thay đổi

---

### **Phase 2: Component Library** (3-4 tuần)

#### 2.1. Base Components
**File target:** `packages/renderer/src/widgets/` (folder mới)

```
widgets/
├── text.zig          # Text với styles, wrapping, truncation
├── input.zig         # Text input với validation, completion
├── button.zig        # Clickable buttons với states
├── list.zig          # Scrollable lists với selection
├── table.zig         # Data tables với sorting, filtering
├── tree.zig          # Tree views (file explorer)
├── tabs.zig          # Tab containers
├── modal.zig         # Modal dialogs
├── progress.zig      # Progress bars, spinners
├── statusbar.zig     # Status bar với segments
├── tooltip.zig       # Hover tooltips
├── help.zig          # Help overlay
└── canvas.zig        # Low-level drawing API
```

**Component specs chi tiết:**

**2.1.1. Text Widget**
```zig
pub const Text = struct {
    content: []const u8,
    style: TextStyle,
    wrap: WrapMode, // .none, .word, .char, .truncate
    align: Align, // .left, .center, .right
    max_width: ?usize,
    
    // Features:
    // - ANSI parsing và custom style override
    // - Emoji rendering
    // - Hyperlink support (OSC 8)
    // - Inline icons (via Nerd Fonts)
};
```

**2.1.2. Input Widget**
```zig
pub const Input = struct {
    value: []u8,
    cursor: usize,
    placeholder: []const u8,
    password: bool,
    validation: ?ValidationFn,
    completion: ?CompletionFn, // Async completion suggestions
    
    // Features:
    // - History navigation (up/down)
    // - Multi-line support (Ctrl+J)
    // - Syntax highlighting (cho code inputs)
    // - Real-time validation feedback
};
```

**2.1.3. Table Widget**
```zig
pub const Table = struct {
    columns: []Column,
    rows: []Row,
    sort_column: ?usize,
    sort_desc: bool,
    filter: ?[]const u8,
    selected: ?usize,
    
    // Features:
    // - Column resizing (drag borders)
    // - Column hiding/showing
    // - Sticky header khi scroll
    // - Row virtualization (cho large datasets)
    // - Export to CSV/JSON
};
```

**2.1.4. Tree Widget** (cho file explorer)
```zig
pub const Tree = struct {
    root: TreeNode,
    expanded: std.AutoHashMap(NodeId, bool),
    selected: ?NodeId,
    
    // Features:
    // - Lazy loading (chỉ load khi expand)
    // - Multi-select (Shift/Ctrl + click)
    // - Keyboard navigation (j/k, g/G, /, *)
    // - File type icons
    // - Git status indicators (M, A, D, U)
};
```

**2.1.5. Progress Widget**
```zig
pub const ProgressBar = struct {
    current: f32,
    total: f32,
    label: []const u8,
    show_percentage: bool,
    show_eta: bool,
    style: ProgressStyle, // .bar, .dots, .spinner
    
    // Features:
    // - Multiple concurrent progress bars
    // - Nested progress (sub-tasks)
    // - ETA calculation
    // - Speed display (items/sec)
};

pub const Spinner = struct {
    frames: [][]const u8,
    current_frame: usize,
    label: []const u8,
    update_ms: u32,
    
    // Built-in spinner styles: dots, line, clock, arrow
};
```

#### 2.2. Advanced Components

**2.2.1. Fuzzy Finder** (`widgets/fuzzy_finder.zig`)
```zig
// Inspired by fzf, telescope.nvim
pub const FuzzyFinder = struct {
    items: [][]const u8,
    query: []u8,
    matches: []Match,
    selected: usize,
    
    // Features:
    // - Fuzzy matching algorithm (Smith-Waterman hoặc similar)
    // - Scoring: prefix bonus, boundary bonus, character bonuses
    // - Preview panel (hiển thị item được select)
    // - Multi-select với Ctrl+Space
    // - Binding customization
    // - Async filtering (không block UI)
};

// Use cases:
// - Ctrl+P: Find files
// - Ctrl+R: Search history
// - Ctrl+Shift+T: Search tabs
// - Ctrl+M: Switch models
// - Ctrl+Shift+C: Switch contexts
```

**2.2.2. Command Palette** (`widgets/command_palette.zig`)
```zig
// Inspired by VS Code Command Palette
pub const CommandPalette = struct {
    commands: []Command,
    query: []u8,
    filtered: []Command,
    selected: usize,
    
    pub const Command = struct {
        id: []const u8,
        label: []const u8,
        description: ?[]const u8,
        shortcut: ?[]const u8,
        callback: *const fn () void,
        category: []const u8,
    };
    
    // Features:
    // - Fuzzy search commands
    // - Recently used commands优先
    // - Context-aware commands (chỉ hiện commands phù hợp)
    // - Keybinding hints
    // - Argument prompts sau khi chọn command
};

// Trigger: Ctrl+Shift+P hoặc F1
```

**2.2.3. Help Overlay** (`widgets/help_overlay.zig`)
```zig
// Interactive help system
pub const HelpOverlay = struct {
    sections: []HelpSection,
    search_query: []u8,
    
    pub const HelpSection = struct {
        title: []const u8,
        bindings: []KeyBinding,
    };
    
    pub const KeyBinding = struct {
        keys: []const u8, // "j", "Ctrl+N", "gd"
        action: []const u8, // "Move down", "New chat"
        context: []const u8, // "global", "chat", "explorer"
    };
    
    // Features:
    // - Searchable help (? hoặc F1)
    // - Context-sensitive (chỉ hiện bindings phù hợp)
    // - Interactive tutorials
    // - Cheatsheet mode (tất cả bindings 1 trang)
};
```

**2.2.4. Notification System** (`widgets/notification.zig`)
```zig
pub const NotificationManager = struct {
    notifications: std.ArrayList(Notification),
    position: Position, // .top_right, .bottom_left, etc.
    
    pub const Notification = struct {
        kind: Kind, // .info, .success, .warning, .error
        title: []const u8,
        message: []const u8,
        duration_ms: ?u32, // null = persistent
        actions: []Action,
    };
    
    // Features:
    // - Toast notifications (auto-dismiss)
    // - Persistent notifications (cần dismiss)
    // - Action buttons trong notification
    // - Notification center (log tất cả notifications)
    // - Do not disturb mode
};
```

---

### **Phase 3: Input & Interaction** (2 tuần)

#### 3.1. Keybinding System
**File target:** `packages/renderer/src/input/keymap.zig`

```zig
pub const Keymap = struct {
    bindings: std.AutoHashMap(KeySequence, Command),
    modes: std.StringHashMap(Keymap), // vim modes: normal, insert, visual
    
    // Features:
    // - Chord support (Ctrl+K, Ctrl+S = sequence)
    // - Mode-specific bindings (vim)
    // - Conflict resolution
    // - Custom binding từ config
    // - Which-key style popup (hiển thị available bindings)
};

// Default bindings đề xuất:
// Global:
//   Ctrl+P: File finder
//   Ctrl+Shift+P: Command palette
//   Ctrl+R: History search
//   Ctrl+/: Toggle help
//   Ctrl+Q: Quit
//   F1: Help
//   
// Chat:
//   Ctrl+Enter: Send message
//   Ctrl+Up/Down: Navigate history
//   Ctrl+L: Clear input
//   Ctrl+Y: Copy code block
//   
// Explorer:
//   Enter: Open file
//   o: Open in split
//   a: New file
//   d: Delete
//   r: Rename
//   c/x/v: Copy/cut/paste
//   gh: Go to home
//   gg/G: Go to top/bottom
//   
// Navigation:
//   Ctrl+Tab: Next tab
//   Ctrl+Shift+Tab: Previous tab
//   Alt+1..9: Jump to tab N
```

#### 3.2. Mouse Support Enhancement
**File target:** `packages/renderer/src/input/mouse.zig`

```zig
// Features cần thêm:
- [ ] Click-to-focus panels
- [ ] Drag-to-resize panes
- [ ] Scroll wheel với acceleration
- [ ] Click-and-drag selection
- [ ] Double-click to select word
- [ ] Triple-click to select line
- [ ] Right-click context menus
- [ ] Middle-click paste
- [ ] Hover tooltips
```

#### 3.3. Clipboard Integration
**File target:** `packages/util/src/clipboard.zig`

```zig
// Cross-platform clipboard:
- [ ] macOS: osascript/pbpaste
- [ ] Linux: xclip/wl-clipboard
- [ ] Windows: powershell/Get-Clipboard
- [ ] OSC 52 escape sequence (cho remote terminals)
```

---

### **Phase 4: Performance Optimization** (1-2 tuần)

#### 4.1. Rendering Optimization
```zig
// Techniques:
- [ ] Dirty rect tracking (chỉ re-render vùng thay đổi)
- [ ] Frame pacing (target 60fps, drop frames nếu cần)
- [ ] Batch rendering (gộp nhiều operations)
- [ ] Cell cache (tránh tính toán lại styled cells)
- [ ] String interning (giảm memory allocations)
- [ ] SIMD cho text wrapping/truncation
```

#### 4.2. Memory Management
```zig
// Strategies:
- [ ] Arena allocator per-frame
- [ ] Object pooling cho widgets
- [ ] Lazy loading cho large lists/tables
- [ ] Virtual scrolling (chỉ render visible items)
- [ ] Streaming cho large outputs
```

#### 4.3. Async Operations
```zig
// Pattern:
- [ ] Background threads cho I/O heavy tasks
- [ ] Non-blocking UI khi waiting for AI responses
- [ ] Cancellation tokens cho long-running operations
- [ ] Progress reporting từ background tasks
```

---

### **Phase 5: Smart Features** (2-3 tuần)

#### 5.1. AI-Powered UX
```zig
// Features:
- [ ] Smart command suggestions (học từ usage patterns)
- [ ] Natural language search ("show me errors from yesterday")
- [ ] Auto-complete cho file paths, git branches, model names
- [ ] Predictive input (gợi ý tiếp theo dựa trên context)
- [ ] Summarization cho long outputs
```

#### 5.2. Context Awareness
```zig
// Smart behaviors:
- [ ] Tự động focus vào panel phù hợp (ví dụ: sau khi run test, focus vào test results)
- [ ] Hide/show panels dựa trên screen size
- [ ] Remember layout per-project
- [ ] Adaptive keybindings (thay đổi dựa trên context)
```

#### 5.3. Session Intelligence
```zig
// Session features:
- [ ] Persistent sessions (resume sau khi close)
- [ ] Session templates (pre-configured layouts)
- [ ] Session sharing (export/import session state)
- [ ] Time-travel debugging (undo/redo across sessions)
```

---

### **Phase 6: Polish & DX** (1-2 tuần)

#### 6.1. Animations
```zig
// Micro-interactions:
- [ ] Smooth scrolling (lerp between positions)
- [ ] Fade in/out cho modals, notifications
- [ ] Slide transitions cho panels
- [ ] Loading skeletons
- [ ] Pulse effects cho active states
- [ ] Number counting animations
```

#### 6.2. Accessibility
```zig
// A11y features:
- [ ] Screen reader support (via terminal announcements)
- [ ] High contrast themes
- [ ] Reduced motion mode
- [ ] Keyboard-only navigation (không cần mouse)
- [ ] Configurable font sizes
```

#### 6.3. Developer Experience
```zig
// Tools cho developers:
- [ ] TUI inspector (debug layout, styles)
- [ ] Performance profiler (frame times, memory)
- [ ] Theme editor (live preview)
- [ ] Keybinding debugger (show active bindings)
- [ ] Widget catalog (demo tất cả widgets)
```

---

## 📅 Timeline tổng thể

| Phase | Duration | Milestone |
|-------|----------|-----------|
| 1. Foundation | 2-3 tuần | Layout engine, theme system, terminal abstraction |
| 2. Components | 3-4 tuần | Full widget library, fuzzy finder, command palette |
| 3. Input | 2 tuần | Keymap system, mouse enhancement, clipboard |
| 4. Performance | 1-2 tuần | Rendering optimization, async patterns |
| 5. Smart Features | 2-3 tuần | AI-powered UX, context awareness |
| 6. Polish | 1-2 tuần | Animations, accessibility, DX tools |
| **Total** | **11-16 tuần** | **Production-ready Modern TUI** |

---

## 🎯 Success Metrics

### UX Metrics
- [ ] Thời gian hoàn thành task phổ biến giảm 50% so với CLI cũ
- [ ] Số keystrokes trung bình giảm 40%
- [ ] Error rate giảm 60% (nhờ validation, confirmations)
- [ ] User satisfaction score > 4.5/5

### Performance Metrics
- [ ] Frame rate ≥ 60fps (95th percentile)
- [ ] Input latency < 16ms (1 frame)
- [ ] Memory usage < 100MB cho typical session
- [ ] Startup time < 500ms

### Adoption Metrics
- [ ] 80% users prefer TUI over raw CLI sau 1 tuần
- [ ] 50% reduction trong support tickets về UX issues
- [ ] Community contributions cho widgets/themes

---

## 🔧 Implementation Priority

### P0 (Must have - Phase 1-2)
1. Layout engine với responsive design
2. Theme system với 3+ built-in themes
3. Basic widgets: Text, Input, List, Button, Modal
4. Fuzzy finder cho files/commands
5. Command palette
6. Help overlay

### P1 (Should have - Phase 3-4)
7. Keybinding customization
8. Mouse support enhancement
9. Performance optimization
10. Progress indicators
11. Notification system
12. Table widget

### P2 (Nice to have - Phase 5-6)
13. Advanced widgets: Tree, Canvas, Charts
14. AI-powered suggestions
15. Animations
16. Accessibility features
17. Session intelligence
18. Developer tools

---

## 📚 Tham khảo & Inspiration

### TUI Libraries
- [Blessed-contrib](https://github.com/yaronn/blessed-contrib) (Node.js)
- [Rich](https://github.com/Textualize/rich) + [Textual](https://github.com/Textualize/textual) (Python)
- [TUIKit](https://github.com/tuikit-org/tuikit) (Rust)
- [Ziglyph TUI](https://github.com/ziglyph/ziglyph) (Zig)
- [Ziggy](https://github.com/egoist/ziggy) (Zig)

### Products
- [lazygit](https://github.com/jesseduffield/lazygit) - Git TUI
- [htop](https://htop.dev/) - Process viewer
- [k9s](https://k9scli.io/) - Kubernetes TUI
- [bottom](https://github.com/ClementTsang/bottom) - System monitor
- [fzf](https://github.com/junegunnham/fzf) - Fuzzy finder
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) - Neovim finder

### Design Systems
- [VS Code Design](https://code.visualstudio.com/api/design-guidelines)
- [Atom UI](https://atom.io/docs)
- [iTerm2](https://iterm2.com/)

---

## 🚀 Quick Start Guide (cho developers)

### Bước 1: Setup development environment
```bash
# Install Zig 0.16.0
curl -L https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz | tar xJ
export PATH=$PATH:./zig-linux-x86_64-0.16.0

# Clone repo
cd /workspace
git checkout -b feature/modern-tui

# Build
zig build
```

### Bước 2: Run TUI dev mode
```bash
# Run with debug flags
zig build run -- agent --tui-debug

# Watch mode cho development
watchexec -e zig -- zig build run
```

### Bước 3: Test components
```bash
# Widget catalog demo
zig build run -- widget-demo

# Performance test
zig build run -- perf-test

# Theme switcher demo
zig build run -- theme-demo
```

---

## 📝 Next Steps

1. **Review & approve plan** - Team discussion về scope và priority
2. **Create feature branches** - Mỗi phase nên là branch riêng
3. **Set up CI/CD** - Automated testing cho TUI components
4. **User research** - Interview users về pain points hiện tại
5. **Prototype nhanh** - Làm 1-2 widgets đầu tiên để validate approach
6. **Iterate** - Release early, release often, gather feedback

---

## 💡 Bonus Ideas (Post-MVP)

- [ ] **Split-screen mode**: Chia terminal thành nhiều panes độc lập
- [ ] **Embedded terminal**: Chạy shell commands trong TUI
- [ ] **Image preview**: Hiển thị images trong terminal (via Kitty/iTerm2 protocols)
- [ ] **Charts & graphs**: Visualize data (CPU, memory, test coverage)
- [ ] **Collaborative editing**: Multiple users trong cùng session
- [ ] **Voice control**: Speech-to-text cho commands
- [ ] **AR/VR mode**: Experimental interface cho Vision Pro

---

*Document này sẽ được cập nhật thường xuyên dựa trên progress và feedback.*
