// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

// Colour themes for the terminal (both the VT surface and the chrome).
//
// A Theme carries the terminal default foreground/background, the 16-colour
// ANSI palette (used for the low SGR colours so that `ls --color` and friends
// follow the theme) plus the tab-bar / panel chrome colours.  The settings
// panel switches the active theme at runtime and Terminal.applyTheme() remaps
// the already-rendered cells so the whole screen recolours immediately.

export class Theme {
  id: string;
  label: string;
  bg: string;
  fg: string;
  cursor: string;
  sel: string;
  palette: string[]; // 16 ANSI colours
  // chrome
  bar: string;
  tab: string;
  tabActive: string;
  tabText: string;
  tabTextActive: string;
  border: string;
  panel: string;
  panelText: string;
  panelSub: string;
  accent: string;

  constructor(id: string, label: string, bg: string, fg: string, cursor: string, sel: string,
    palette: string[], bar: string, tab: string, tabActive: string, tabText: string,
    tabTextActive: string, border: string, panel: string, panelText: string,
    panelSub: string, accent: string) {
    this.id = id;
    this.label = label;
    this.bg = bg;
    this.fg = fg;
    this.cursor = cursor;
    this.sel = sel;
    this.palette = palette;
    this.bar = bar;
    this.tab = tab;
    this.tabActive = tabActive;
    this.tabText = tabText;
    this.tabTextActive = tabTextActive;
    this.border = border;
    this.panel = panel;
    this.panelText = panelText;
    this.panelSub = panelSub;
    this.accent = accent;
  }
}

const DARK_PALETTE: string[] = [
  '#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
  '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff'
];

const LIGHT_PALETTE: string[] = [
  '#2e3436', '#cc0000', '#4e9a06', '#c4a000', '#3465a4', '#75507b', '#06989a', '#d3d7cf',
  '#555753', '#ef2929', '#8ae234', '#fce94f', '#729fcf', '#ad7fa8', '#34e2e2', '#eeeeec'
];

export const THEME_DARK: Theme = new Theme(
  'dark', '深色',
  '#1e1e1e', '#dcdfe4', 'rgba(220,225,235,0.72)', '#3a5a8c',
  DARK_PALETTE,
  '#2b2b2b', '#2b2b2b', '#1e1e1e', '#9aa0a6', '#f5f5f5', '#3a3a3a',
  '#262626', '#e6e6e6', '#9aa0a6', '#4c8bf5'
);

export const THEME_LIGHT: Theme = new Theme(
  'light', '浅色',
  '#ffffff', '#2e3436', 'rgba(40,44,52,0.65)', '#bfd8ff',
  LIGHT_PALETTE,
  '#e8e8e8', '#e8e8e8', '#ffffff', '#5f6368', '#1f1f1f', '#c9c9c9',
  '#f4f4f4', '#1f1f1f', '#5f6368', '#1a73e8'
);

export const THEMES: Theme[] = [THEME_DARK, THEME_LIGHT];

export function themeById(id: string): Theme {
  for (let i = 0; i < THEMES.length; i++) {
    if (THEMES[i].id === id) { return THEMES[i]; }
  }
  return THEME_DARK;
}
