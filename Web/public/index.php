<?php

declare(strict_types=1);

require __DIR__ . '/../bootstrap.php';

use MarkdownEditor\Workspace;
use MarkdownEditor\WorkspaceError;

// Resolving the workspace here means a misconfigured install says so on a
// styled page instead of failing later inside a fetch the user cannot see.
$workspaceName = '';
$startupError = null;
try {
    $root = getenv('MARKDOWN_EDITOR_WORKSPACE')
        ?: dirname(__DIR__) . DIRECTORY_SEPARATOR . 'workspace';
    $workspaceName = (new Workspace($root))->name();
} catch (WorkspaceError $error) {
    $startupError = $error;
}

// Bumped when assets change so browsers pick up a deploy without a hard reload.
$assetVersion = '1';

?><!DOCTYPE html>
<html lang="en" data-theme-color="blue" data-appearance="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Markdown Editor</title>
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="css/themes.css?v=<?= $assetVersion ?>">
<link rel="stylesheet" href="css/app.css?v=<?= $assetVersion ?>">
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
</svg>

<script type="module" src="app/main.js?v=<?= $assetVersion ?>"></script>
<?php endif; ?>
</body>
</html>
