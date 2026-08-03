// Right-click menus (PRD WF-2).
//
// The menu bar builds its lists from a static definition and anchors them to a
// button. A context menu is the same list anchored to a point instead, so this
// reuses the `me-menu` markup and only owns the placement, dismissal, and
// keyboard handling.

const layer = () => document.getElementById('popoverLayer');

let openMenu = null;

/**
 * @param {Array<{title?: string, action?: () => void, separator?: boolean, disabled?: boolean}>} items
 * @param {number} x viewport coordinate
 * @param {number} y viewport coordinate
 */
export function showContextMenu(items, x, y) {
  closeContextMenu();

  const list = document.createElement('ul');
  list.className = 'me-menu__list me-menu__list--context';
  list.setAttribute('role', 'menu');

  for (const item of items) {
    const row = document.createElement('li');
    if (item.separator) {
      row.className = 'me-menu__separator';
      row.setAttribute('role', 'separator');
      list.append(row);
      continue;
    }

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'me-menu__item';
    button.setAttribute('role', 'menuitem');
    button.disabled = item.disabled === true;
    button.append(Object.assign(document.createElement('span'), {
      className: 'me-menu__check',
    }));
    button.append(Object.assign(document.createElement('span'), {
      textContent: item.title ?? '',
    }));
    button.addEventListener('click', () => {
      closeContextMenu();
      item.action?.();
    });
    row.append(button);
    list.append(row);
  }

  // Measured off-screen first, so the flip decision uses the real size.
  list.style.left = '-9999px';
  list.style.top = '0';
  layer().append(list);

  const size = list.getBoundingClientRect();
  const margin = 6;
  const left = Math.max(
    margin,
    x + size.width + margin > window.innerWidth ? x - size.width : x
  );
  const top = Math.max(
    margin,
    y + size.height + margin > window.innerHeight ? y - size.height : y
  );
  list.style.left = `${left}px`;
  list.style.top = `${top}px`;

  const dismiss = (event) => {
    if (event.type === 'keydown' && event.key !== 'Escape') return;
    if (event.type === 'mousedown' && list.contains(event.target)) return;
    closeContextMenu();
  };

  openMenu = { list, dismiss };
  document.addEventListener('mousedown', dismiss, true);
  document.addEventListener('keydown', dismiss, true);
  window.addEventListener('blur', dismiss);
  window.addEventListener('resize', dismiss);
  document.addEventListener('scroll', dismiss, true);

  list.querySelector('.me-menu__item:not(:disabled)')?.focus();
}

export function closeContextMenu() {
  if (!openMenu) return;
  const { list, dismiss } = openMenu;
  openMenu = null;
  document.removeEventListener('mousedown', dismiss, true);
  document.removeEventListener('keydown', dismiss, true);
  window.removeEventListener('blur', dismiss);
  window.removeEventListener('resize', dismiss);
  document.removeEventListener('scroll', dismiss, true);
  list.remove();
}
