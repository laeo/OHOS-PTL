// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Physical keycode -> rime key value table.
 * Unknown keys map to "" so the caller passes them through to the app untouched.
 */
import { KeyCode } from '@kit.InputKit';

export function GetHardKeyValue(keyCode: number): string {
  const map: Map<number, string> = new Map();
  map.set(KeyCode.KEYCODE_0, '0');
  map.set(KeyCode.KEYCODE_1, '1');
  map.set(KeyCode.KEYCODE_2, '2');
  map.set(KeyCode.KEYCODE_3, '3');
  map.set(KeyCode.KEYCODE_4, '4');
  map.set(KeyCode.KEYCODE_5, '5');
  map.set(KeyCode.KEYCODE_6, '6');
  map.set(KeyCode.KEYCODE_7, '7');
  map.set(KeyCode.KEYCODE_8, '8');
  map.set(KeyCode.KEYCODE_9, '9');
  map.set(KeyCode.KEYCODE_A, 'a');
  map.set(KeyCode.KEYCODE_B, 'b');
  map.set(KeyCode.KEYCODE_C, 'c');
  map.set(KeyCode.KEYCODE_D, 'd');
  map.set(KeyCode.KEYCODE_E, 'e');
  map.set(KeyCode.KEYCODE_F, 'f');
  map.set(KeyCode.KEYCODE_G, 'g');
  map.set(KeyCode.KEYCODE_H, 'h');
  map.set(KeyCode.KEYCODE_I, 'i');
  map.set(KeyCode.KEYCODE_J, 'j');
  map.set(KeyCode.KEYCODE_K, 'k');
  map.set(KeyCode.KEYCODE_L, 'l');
  map.set(KeyCode.KEYCODE_M, 'm');
  map.set(KeyCode.KEYCODE_N, 'n');
  map.set(KeyCode.KEYCODE_O, 'o');
  map.set(KeyCode.KEYCODE_P, 'p');
  map.set(KeyCode.KEYCODE_Q, 'q');
  map.set(KeyCode.KEYCODE_R, 'r');
  map.set(KeyCode.KEYCODE_S, 's');
  map.set(KeyCode.KEYCODE_T, 't');
  map.set(KeyCode.KEYCODE_U, 'u');
  map.set(KeyCode.KEYCODE_V, 'v');
  map.set(KeyCode.KEYCODE_W, 'w');
  map.set(KeyCode.KEYCODE_X, 'x');
  map.set(KeyCode.KEYCODE_Y, 'y');
  map.set(KeyCode.KEYCODE_Z, 'z');
  map.set(KeyCode.KEYCODE_COMMA, ',');
  map.set(KeyCode.KEYCODE_PERIOD, '.');
  map.set(KeyCode.KEYCODE_APOSTROPHE, '\'');
  map.set(2047, 'KEYCODE_SHIFT_LEFT');
  map.set(2048, 'KEYCODE_SHIFT_RIGHT');
  map.set(KeyCode.KEYCODE_SPACE, ' ');
  map.set(2054, 'KEYCODE_ENTER');
  map.set(2055, 'KEYCODE_DEL');
  map.set(KeyCode.KEYCODE_GRAVE, '`');
  map.set(KeyCode.KEYCODE_MINUS, '-');
  map.set(KeyCode.KEYCODE_EQUALS, '=');
  map.set(KeyCode.KEYCODE_LEFT_BRACKET, '[');
  map.set(KeyCode.KEYCODE_RIGHT_BRACKET, ']');
  map.set(KeyCode.KEYCODE_BACKSLASH, '\\');
  map.set(KeyCode.KEYCODE_SEMICOLON, ';');
  map.set(KeyCode.KEYCODE_APOSTROPHE, '\'');
  map.set(KeyCode.KEYCODE_SLASH, '/');
  map.set(KeyCode.KEYCODE_AT, '@');
  map.set(KeyCode.KEYCODE_PLUS, '+');
  map.set(2071, 'KEYCODE_FORWARD_DEL');
  if (!map.has(keyCode)) {
    return '';
  }
  const v = map.get(keyCode);
  if (!v) {
    return '';
  }
  return v;
}
