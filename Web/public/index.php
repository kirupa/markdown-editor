<?php

declare(strict_types=1);

// A shared host rarely lets you repoint the document root, so the public files
// end up in a URL subdirectory while the rest of the app stays above it, out
// of reach of the web. MARKDOWN_EDITOR_HOME names that private folder; unset,
// the layout is the one in this repository.
$home = getenv('MARKDOWN_EDITOR_HOME') ?: ($_SERVER['MARKDOWN_EDITOR_HOME'] ?? '');
require (is_string($home) && $home !== '' ? rtrim($home, '/\\') : __DIR__ . '/..')
    . '/bootstrap.php';

use MarkdownEditor\Workspace;
use MarkdownEditor\WorkspaceError;

// Resolving the workspace here means a misconfigured install says so on a
// styled page instead of failing later inside a fetch the user cannot see.
$workspaceName = '';
$startupError = null;
try {
    $workspaceName = Workspace::prepare()->name();
} catch (WorkspaceError $error) {
    $startupError = $error;
}

// Cache busting.
//
// A query string only versions the URLs written on this page. The imports
// *inside* a module are plain static paths that no query string reaches, so a
// cache holding a new main.js against a stale welcome.js loads a module graph
// that fails outright — which is exactly what a 31-day CDN policy did to the
// first deploy of this file. A deploy therefore puts the whole asset tree in a
// directory named after its contents and writes asset-base.php beside this
// file; every module URL then changes together, and relative imports inherit
// the versioned directory for free. Locally there is no such file and assets
// are served straight out of app/ and css/.
$assetBase = '';
if (is_file(__DIR__ . '/asset-base.php')) {
    $assetBase = trim((string) require __DIR__ . '/asset-base.php', '/');
}
$asset = static fn (string $path): string => $assetBase === '' ? $path : "$assetBase/$path";

?><!DOCTYPE html>
<html lang="en" data-theme-color="blue" data-appearance="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Markdown Editor</title>
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="<?= htmlspecialchars($asset('css/themes.css'), ENT_QUOTES) ?>">
<link rel="stylesheet" href="<?= htmlspecialchars($asset('css/app.css'), ENT_QUOTES) ?>">
</head>
<body>
<?php if ($startupError !== null): ?>
<div class="me-startup-error">
  <h1>Markdown Editor cannot start</h1>
  <p><?= htmlspecialchars($startupError->getMessage(), ENT_QUOTES) ?></p>
  <p class="me-startup-error__recovery">
    <?= htmlspecialchars($startupError->recoverySuggestion(), ENT_QUOTES) ?>
  </p>
</div>
<?php else: ?>
<div class="me-app" id="app" hidden>

  <div class="me-menubar" role="menubar" id="menubar">
    <span class="me-menubar__title">Markdown Editor</span>
  </div>

  <div class="me-toolbar" id="toolbar"></div>

  <!-- Mobile layout (WB-*): replaces the menu bar and toolbar above. -->
  <div class="me-mobile" id="mobileBar" hidden></div>

  <div class="me-body">
    <aside class="me-sidebar" id="sidebar" aria-label="File explorer">
      <div class="me-sidebar__header">
        <button type="button" class="me-sidebar__path" id="explorerPath"
                aria-haspopup="menu" aria-expanded="false">
          <span id="explorerPathLabel"><?= htmlspecialchars($workspaceName, ENT_QUOTES) ?></span>
          <svg viewBox="0 0 10 6" aria-hidden="true" class="me-chevron">
            <path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/>
          </svg>
        </button>
        <button type="button" class="me-icon-button" id="explorerNewDocument"
                title="New document" aria-label="New document">
          <svg viewBox="0 0 16 16" aria-hidden="true"><use href="#icon-new-document"/></svg>
        </button>
        <button type="button" class="me-icon-button" id="explorerNewFolder"
                title="New folder" aria-label="New folder">
          <svg viewBox="0 0 16 16" aria-hidden="true"><use href="#icon-new-folder"/></svg>
        </button>
        <button type="button" class="me-icon-button" id="explorerReveal"
                title="Show the current document's folder" aria-label="Show the current document's folder">
          <svg viewBox="0 0 16 16" aria-hidden="true"><use href="#icon-target"/></svg>
        </button>
        <button type="button" class="me-icon-button" id="explorerRefresh"
                title="Refresh" aria-label="Refresh">
          <svg viewBox="0 0 16 16" aria-hidden="true"><use href="#icon-refresh"/></svg>
        </button>
      </div>
      <div class="me-sidebar__tree" id="explorerTree" role="tree" tabindex="0"></div>
    </aside>

    <div class="me-divider" id="sidebarDivider" role="separator"
         aria-orientation="vertical" aria-label="Sidebar width" tabindex="0"></div>

    <main class="me-editor" id="editor">
      <div class="me-pane me-pane--rich" id="richPane">
        <div class="me-surface" id="richSurface" role="textbox"
             aria-multiline="true" aria-label="Rendered Markdown" spellcheck="true"></div>
      </div>
      <div class="me-divider me-divider--pane" id="paneDivider" role="separator"
           aria-orientation="vertical" aria-label="Preview width" tabindex="0"></div>
      <div class="me-pane me-pane--source" id="sourcePane">
        <div class="me-surface me-surface--source" id="sourceSurface" role="textbox"
             aria-multiline="true" aria-label="Markdown source" spellcheck="false"></div>
      </div>
    </main>
  </div>

  <div class="me-statusbar" id="statusbar">
    <span id="statusDocument">No document</span>
    <span class="me-statusbar__spacer"></span>
    <span id="statusSaved"></span>
  </div>

  <div class="me-format" id="formatBar" role="toolbar" aria-label="Formatting" hidden></div>
  <div class="me-drawer-scrim" id="drawerScrim" hidden></div>
</div>

<div class="me-welcome-backdrop" id="welcome" hidden></div>
<div class="me-popover-layer" id="popoverLayer"></div>
<div class="me-alert-layer" id="alertLayer"></div>

<svg style="display:none" aria-hidden="true">
  <symbol id="icon-target" viewBox="0 0 16 16">
    <circle cx="8" cy="8" r="5.2" fill="none" stroke="currentColor" stroke-width="1.4"/>
    <circle cx="8" cy="8" r="1.6" fill="currentColor"/>
  </symbol>
  <symbol id="icon-refresh" viewBox="0 0 16 16">
    <path d="M13 8a5 5 0 1 1-1.6-3.7" fill="none" stroke="currentColor"
          stroke-width="1.4" stroke-linecap="round"/>
    <path d="M13 2.2V5h-2.8" fill="none" stroke="currentColor"
          stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
  </symbol>
  <symbol id="icon-new-document" viewBox="0 0 16 16">
    <path d="M3.6 1.9h5L12 5.2v4.1" fill="none" stroke="currentColor" stroke-width="1.3"
          stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M3.6 1.9v12.2h4.2" fill="none" stroke="currentColor" stroke-width="1.3"
          stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M8.4 2v3.4h3.4" fill="none" stroke="currentColor" stroke-width="1.3"
          stroke-linejoin="round"/>
    <path d="M11.6 10.4v4.2M9.5 12.5h4.2" fill="none" stroke="currentColor"
          stroke-width="1.4" stroke-linecap="round"/>
  </symbol>
  <symbol id="icon-new-folder" viewBox="0 0 16 16">
    <path d="M1.8 12.4V4a1.2 1.2 0 0 1 1.2-1.2h2.6l1.3 1.5h4.3" fill="none"
          stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M1.8 12.4a1 1 0 0 0 1 1h5.1" fill="none" stroke="currentColor"
          stroke-width="1.3" stroke-linecap="round"/>
    <path d="M14.2 5.5v2.3" fill="none" stroke="currentColor" stroke-width="1.3"
          stroke-linecap="round"/>
    <path d="M11.9 11.4v4.2M9.8 13.5H14" fill="none" stroke="currentColor"
          stroke-width="1.4" stroke-linecap="round"/>
  </symbol>
</svg>

<script type="module" src="<?= htmlspecialchars($asset('app/main.js'), ENT_QUOTES) ?>"></script>
<?php endif; ?>
</body>
</html>
