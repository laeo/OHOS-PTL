// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Shares the single ImeController instance between the IME extension process and the
 * candidate panel page (they live in the same bundle/ability process tree).
 */
import { ImeController } from './ImeController';

export let imeController: ImeController | undefined = undefined;

export function setImeController(c: ImeController): void {
  imeController = c;
}