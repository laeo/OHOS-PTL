// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Static schema table. The settings page runs in the UIAbility process, which has no
 * librime session, so the schema ids/names are duplicated here (same as the engine data
 * in /system/etc/rime/default.yaml).
 *
 * Only one schema is shipped: two schemas may not share `dictionary: rime_ice`, because
 * librime compiles <dict>.prism.bin once per deployment and the double-pinyin schema then
 * poisons the full-pinyin one (see fix_rime_rebuild/SUMMARY.md §1).
 */

export interface RimeSchemaInfo {
  id: string;
  name: string;
}

export const RIME_SCHEMAS: RimeSchemaInfo[] = [
  { id: 'rime_ice_ohos', name: '雾凇拼音' }
];

export function schemaNameOf(id: string): string {
  for (let i = 0; i < RIME_SCHEMAS.length; i++) {
    if (RIME_SCHEMAS[i].id === id) {
      return RIME_SCHEMAS[i].name;
    }
  }
  return id;
}