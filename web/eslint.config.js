import js from '@eslint/js';
import globals from 'globals';

/**
 * Markup strings are never parsed in this code base: every element is created through
 * the DOM API (see src/js/core/dom.js). The rules below keep it that way, which is what
 * allows the strict Content-Security-Policy and rules out DOM-based XSS by construction.
 */
const noMarkupInjection = [
  { property: 'innerHTML', message: 'Build DOM nodes with h() from core/dom.js; never parse markup strings.' },
  { property: 'outerHTML', message: 'Build DOM nodes with h() from core/dom.js; never parse markup strings.' },
  { property: 'insertAdjacentHTML', message: 'Build DOM nodes with h() from core/dom.js; never parse markup strings.' },
  { object: 'document', property: 'write', message: 'document.write is not allowed.' },
  { object: 'document', property: 'writeln', message: 'document.writeln is not allowed.' },
  { property: 'cssText', message: 'Inline styles are blocked by the Content-Security-Policy; use CSS classes.' },
];

const common = {
  ...js.configs.recommended.rules,
  eqeqeq: ['error', 'always'],
  curly: ['error', 'multi-line'],
  'no-var': 'error',
  'prefer-const': 'error',
  'no-implicit-globals': 'error',
  'no-eval': 'error',
  'no-implied-eval': 'error',
  'no-new-func': 'error',
  'no-script-url': 'error',
  'no-shadow': 'error',
  'no-throw-literal': 'error',
  'no-unused-vars': ['error', { argsIgnorePattern: '^_', caughtErrors: 'none' }],
  'no-use-before-define': ['error', { functions: false, classes: true, variables: true }],
  'no-await-in-loop': 'off',
  'no-console': 'error',
  'no-restricted-properties': ['error', ...noMarkupInjection],
  'no-restricted-syntax': [
    'error',
    { selector: "CallExpression[callee.property.name='setAttribute'][arguments.0.value='style']", message: 'Inline styles are blocked by the Content-Security-Policy; use CSS classes.' },
    { selector: "CallExpression[callee.property.name='setAttribute'][arguments.0.value=/^on/i]", message: 'Inline event handlers are blocked by the Content-Security-Policy; use addEventListener.' },
  ],
};

export default [
  { ignores: ['dist/**', 'node_modules/**', 'test-results/**', '.e2e/**'] },
  {
    files: ['src/js/**/*.js'],
    languageOptions: { ecmaVersion: 2023, sourceType: 'module', globals: { ...globals.browser } },
    rules: common,
  },
  {
    // The pure core is unit-tested under Node, so it must not depend on the DOM (dom.js is the one exception).
    files: ['src/js/core/*.js'],
    ignores: ['src/js/core/dom.js'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      globals: { ...globals['shared-node-browser'], URLSearchParams: 'readonly', Response: 'readonly', FormData: 'readonly', DOMException: 'readonly' },
    },
    rules: {
      ...common,
      'no-restricted-globals': ['error', 'window', 'document', 'navigator', 'localStorage', 'sessionStorage', 'location', 'fetch'],
    },
  },
  {
    files: ['scripts/**/*.mjs', 'tests/**/*.js', 'tests/**/*.mjs', 'eslint.config.js'],
    languageOptions: { ecmaVersion: 2023, sourceType: 'module', globals: { ...globals.node } },
    rules: { ...common, 'no-console': 'off' },
  },
  {
    // Functions passed to page.evaluate() run inside the browser.
    files: ['tests/e2e/**/*.js', 'tests/e2e/**/*.mjs'],
    languageOptions: { globals: { ...globals.node, ...globals.browser } },
  },
];
