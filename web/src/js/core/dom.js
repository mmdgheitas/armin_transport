/**
 * Minimal DOM construction helpers.
 *
 * Everything is built with createElement/textContent. Markup strings are never
 * parsed (no innerHTML and friends; ESLint enforces it), so data from the API can
 * not inject HTML, and the strict Content-Security-Policy needs no exceptions.
 */

const SVG_NS = 'http://www.w3.org/2000/svg';

function appendChildren(parent, children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false || child === true) continue;
    if (Array.isArray(child)) appendChildren(parent, child);
    else parent.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

function applyProps(element, props) {
  for (const [name, value] of Object.entries(props)) {
    if (value === null || value === undefined || value === false) continue;
    if (name === 'class') element.setAttribute('class', Array.isArray(value) ? value.filter(Boolean).join(' ') : value);
    else if (name === 'dataset') Object.assign(element.dataset, value);
    else if (name.startsWith('on') && typeof value === 'function') element.addEventListener(name.slice(2).toLowerCase(), value);
    else if (name === 'value') continue; // assigned by h() after the children exist (a <select> needs its options first)
    else if (name === 'checked' || name === 'selected' || name === 'disabled' || name === 'indeterminate') element[name] = value;
    else element.setAttribute(name, value === true ? '' : String(value));
  }
}

/**
 * Creates an element: `h('button', { class: 'btn', type: 'button', onClick }, 'متن')`.
 * String children become text nodes; `null`/`false` children are skipped; arrays are flattened.
 */
export function h(tag, props = {}, ...children) {
  const element = document.createElement(tag);
  applyProps(element, props ?? {});
  appendChildren(element, children);
  if (props && props.value !== null && props.value !== undefined) element.value = props.value;
  return element;
}

export function clear(node) {
  node.replaceChildren();
  return node;
}

export function mount(parent, ...children) {
  parent.replaceChildren();
  appendChildren(parent, children);
  return parent;
}

/** Text that must keep its left-to-right order inside right-to-left content (codes, user names, file names). */
export function ltr(text, className = '') {
  return h('bdi', { dir: 'ltr', class: className }, text);
}

// Icon outlines adapted from Feather (https://feathericons.com, MIT License).
const ICONS = {
  grid: ['r:3,3,7,7', 'r:14,3,7,7', 'r:14,14,7,7', 'r:3,14,7,7'],
  package: [
    'M16.5 9.4l-9-5.19',
    'M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z',
    'M3.27 6.96L12 12.01l8.73-5.05',
    'M12 22.08V12',
  ],
  briefcase: ['r:2,7,20,14,2', 'M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16'],
  users: ['M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2', 'c:9,7,4', 'M23 21v-2a4 4 0 0 0-3-3.87', 'M16 3.13a4 4 0 0 1 0 7.75'],
  user: ['M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2', 'c:12,7,4'],
  sliders: ['M4 21v-7', 'M4 10V3', 'M12 21v-9', 'M12 8V3', 'M20 21v-5', 'M20 12V3', 'M1 14h6', 'M9 8h6', 'M17 16h6'],
  list: ['M8 6h13', 'M8 12h13', 'M8 18h13', 'M3 6h.01', 'M3 12h.01', 'M3 18h.01'],
  logout: ['M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4', 'M16 17l5-5-5-5', 'M21 12H9'],
  plus: ['M12 5v14', 'M5 12h14'],
  search: ['c:11,11,8', 'M21 21l-4.35-4.35'],
  download: ['M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4', 'M7 10l5 5 5-5', 'M12 15V3'],
  upload: ['M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4', 'M17 8l-5-5-5 5', 'M12 3v12'],
  trash: ['M3 6h18', 'M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2', 'M10 11v6', 'M14 11v6'],
  edit: ['M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z'],
  copy: ['r:9,9,13,13,2', 'M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1'],
  eye: ['M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z', 'c:12,12,3'],
  'eye-off': [
    'M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24',
    'M1 1l22 22',
  ],
  archive: ['M21 8v13H3V8', 'M1 3h22v5H1z', 'M10 12h4'],
  restore: ['M1 4v6h6', 'M3.51 15a9 9 0 1 0 2.13-9.36L1 10'],
  refresh: ['M23 4v6h-6', 'M1 20v-6h6', 'M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15'],
  key: ['M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4'],
  x: ['M18 6L6 18', 'M6 6l12 12'],
  check: ['M20 6L9 17l-5-5'],
  menu: ['M3 12h18', 'M3 6h18', 'M3 18h18'],
  file: ['M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z', 'M14 2v6h6', 'M16 13H8', 'M16 17H8', 'M10 9H8'],
  alert: ['M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z', 'M12 9v4', 'M12 17h.01'],
  info: ['c:12,12,10', 'M12 16v-4', 'M12 8h.01'],
  truck: ['r:1,3,15,13', 'M16 8h4l3 3v5h-7z', 'c:5.5,18.5,2.5', 'c:18.5,18.5,2.5'],
  clock: ['c:12,12,10', 'M12 6v6l4 2'],
  lock: ['r:3,11,18,11,2', 'M7 11V7a5 5 0 0 1 10 0v4'],
  shield: ['M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'],
  'chevron-right': ['M9 18l6-6-6-6'],
  'chevron-left': ['M15 18l-6-6 6-6'],
  ban: ['c:12,12,10', 'M4.93 4.93l14.14 14.14'],
};

function svgElement(name, attributes) {
  const element = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  return element;
}

/** A decorative inline SVG icon (hidden from assistive technology; pair it with visible or aria text). */
export function icon(name, { size = 18, className = '' } = {}) {
  const svg = svgElement('svg', {
    viewBox: '0 0 24 24',
    width: size,
    height: size,
    fill: 'none',
    stroke: 'currentColor',
    'stroke-width': 2,
    'stroke-linecap': 'round',
    'stroke-linejoin': 'round',
    'aria-hidden': 'true',
    focusable: 'false',
    class: `icon ${className}`.trim(),
  });
  for (const shape of ICONS[name] ?? []) {
    if (shape.startsWith('c:')) {
      const [cx, cy, r] = shape.slice(2).split(',');
      svg.append(svgElement('circle', { cx, cy, r }));
    } else if (shape.startsWith('r:')) {
      const [x, y, width, height, rx = 0] = shape.slice(2).split(',');
      svg.append(svgElement('rect', { x, y, width, height, rx }));
    } else {
      svg.append(svgElement('path', { d: shape }));
    }
  }
  return svg;
}

/** Saves a Blob as a file through a temporary object URL. */
export function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = h('a', { href: url, download: filename, hidden: true });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}
