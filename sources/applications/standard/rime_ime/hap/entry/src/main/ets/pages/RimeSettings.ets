// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Rime settings page (com.ohos.rimeime / RimeSettingsAbility).
 *
 * Standard ArkUI only (see ARKUI_UI_STANDARD.md): Tabs + Scroll + Toggle + Slider + Select
 * + AlertDialog/Toast, system semantic colours, 48vp rows, 12vp radius.
 *
 * NOTE 1: compileSdk 26.0.0 on this branch ships neither `Preference` nor `RadioGroup`, so a
 * setting row is a `Row` and the scheme choice is a `Select`; both are on the standard's
 * whitelist.
 * NOTE 2: the tab bodies are built with `Scroll` + `Column`, NOT with `List`/`ListItemGroup`.
 * On this platform (virgl + Mesa 25 back-buffer readback) a lazy `List` only materialises the
 * rows of the first viewport: the scroll extent stops early and everything below is
 * unreachable. A plain Scroll always lays out its whole Column. Same symptom as the system
 * Settings app on this image.
 *
 * Persistence: <filesDir>/rime_settings.json -- the very same file ImeController reads on
 * inputStart (shared bundle sandbox). Engine switches are applied by the IME process, because
 * this settings ability has no librime session of its own; `menu/page_size` is written to
 * <filesDir>/rime/default.custom.yaml and needs an IME restart.
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { RIME_SCHEMAS, schemaNameOf, RimeSchemaInfo } from '../model/RimeSchemas';

const SETTINGS_FILE: string = 'rime_settings.json';

interface PersistedOptions {
  punct?: boolean;
  ascii_punct?: boolean;
  emoji?: boolean;
  enable_sentence?: boolean;
  enable_completion?: boolean;
}

interface PersistedSettings {
  schema?: string;
  traditional?: boolean;
  pageSize?: number;
  options?: PersistedOptions;
}

class SettingsStore {
  path: string = '';
  schema: string = RIME_SCHEMAS[0].id;
  traditional: boolean = false;
  pageSize: number = 7;
  options: PersistedOptions = {
    punct: true,
    ascii_punct: false,
    emoji: false,
    enable_sentence: true,
    enable_completion: false
  };

  constructor(ctx: common.UIAbilityContext) {
    this.path = ctx.filesDir + '/' + SETTINGS_FILE;
    this.load();
  }

  load(): void {
    try {
      const text = fileIo.readTextSync(this.path);
      if (text === undefined || text.length === 0) {
        return;
      }
      const cfg = JSON.parse(text) as PersistedSettings;
      if (cfg.schema !== undefined && cfg.schema.length > 0) {
        this.schema = cfg.schema;
      }
      if (cfg.traditional !== undefined) {
        this.traditional = cfg.traditional;
      }
      if (cfg.pageSize !== undefined && cfg.pageSize >= 3 && cfg.pageSize <= 9) {
        this.pageSize = cfg.pageSize;
      }
      if (cfg.options !== undefined && cfg.options !== null) {
        this.options = cfg.options;
      }
    } catch (e) {
      // first run: keep defaults
    }
  }

  save(): void {
    const cfg: PersistedSettings = {
      schema: this.schema,
      traditional: this.traditional,
      pageSize: this.pageSize,
      options: this.options
    };
    const f = fileIo.openSync(this.path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, JSON.stringify(cfg));
    fileIo.closeSync(f);
  }

  reset(): void {
    this.schema = RIME_SCHEMAS[0].id;
    this.traditional = false;
    this.pageSize = 7;
    this.options = {
      punct: true,
      ascii_punct: false,
      emoji: false,
      enable_sentence: true,
      enable_completion: false
    };
  }
}

@Entry
@Component
struct RimeSettings {
  @State private schema: string = RIME_SCHEMAS[0].id;
  @State private traditional: boolean = false;
  @State private pageSize: number = 7;
  @State private punct: boolean = true;
  @State private asciiPunct: boolean = false;
  @State private emoji: boolean = false;
  @State private enableSentence: boolean = true;
  @State private enableCompletion: boolean = false;
  @State private status: string = '';
  @State private settingsPath: string = '';
  private schemas: RimeSchemaInfo[] = RIME_SCHEMAS;

  private store: SettingsStore | undefined = undefined;
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.store = new SettingsStore(this.ctx);
    this.schema = this.store.schema;
    this.traditional = this.store.traditional;
    this.pageSize = this.store.pageSize;
    this.punct = this.store.options.punct === true;
    this.asciiPunct = this.store.options.ascii_punct === true;
    this.emoji = this.store.options.emoji === true;
    this.enableSentence = this.store.options.enable_sentence !== false;
    this.enableCompletion = this.store.options.enable_completion === true;
    this.settingsPath = this.store.path;
  }

  private toast(msg: Resource): void {
    promptAction.showToast({ message: msg, showMode: promptAction.ToastShowMode.TOP_MOST });
  }

  private updateStatus(text: string): void {
    this.status = text;
    setTimeout(() => {
      this.status = '';
    }, 3000);
  }

  private save(): void {
    if (this.store === undefined) {
      return;
    }
    this.store.schema = this.schema;
    this.store.traditional = this.traditional;
    this.store.pageSize = this.pageSize;
    this.store.options = {
      punct: this.punct,
      ascii_punct: this.asciiPunct,
      emoji: this.emoji,
      enable_sentence: this.enableSentence,
      enable_completion: this.enableCompletion
    };
    this.store.save();
    this.toast($r('app.string.settings_saved'));
    this.updateStatus($r('app.string.settings_saved_detail').toString());
  }

  private confirmReset(): void {
    AlertDialog.show({
      title: $r('app.string.settings_reset'),
      message: $r('app.string.settings_reset_confirm'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.settings_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.settings_reset'),
        action: () => {
          this.doReset();
        }
      }
    });
  }

  private doReset(): void {
    if (this.store === undefined) {
      return;
    }
    this.store.reset();
    this.store.save();
    this.schema = this.store.schema;
    this.traditional = this.store.traditional;
    this.pageSize = this.store.pageSize;
    this.punct = this.store.options.punct === true;
    this.asciiPunct = this.store.options.ascii_punct === true;
    this.emoji = this.store.options.emoji === true;
    this.enableSentence = this.store.options.enable_sentence !== false;
    this.enableCompletion = this.store.options.enable_completion === true;
    this.toast($r('app.string.settings_reset_done'));
  }

  private schemaOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.schemas.length; i++) {
      opts.push({ value: this.schemas[i].name });
    }
    return opts;
  }

  // ---------- layout primitives ----------
  //
  // Layout rules -- fix "Tabs 离内容太远 / 没有分区底色，看上去像布局错乱":
  //
  // 1) WHY the old page looked broken (this is the actual root cause, not a spacing tweak):
  //    the page painted itself `ohos_id_color_background` (= #ffffffff in the light theme)
  //    AND every group card / the tab bar painted `ohos_id_color_list_card_bg`
  //    (= #ffffffff as well). Card and page are *the same colour*, so no card boundary was
  //    ever drawn: the rows appeared to float on bare white. The blank strip between the tab
  //    bar and the first row was then read as "the content is pushed far away", and the
  //    missing surface boundary was read as "broken layout".
  //    Source of truth for the values: base/global/system_resources/systemres/main/resources/
  //      base/element/color.json -> ohos_id_color_background #ffffffff,
  //                                    ohos_id_color_list_card_bg #ffffffff (identical!)
  //      dark/element/color.json    -> #ff18181a / #ff202224
  // 2) FIX -- one consistent surface model, all from system semantic colours so it follows
  //    light/dark automatically:
  //      PAGE      = ohos_id_color_background        #ffffff / #18181a  content canvas
  //      SURFACE   = ohos_id_color_sub_background    #f1f3f5 / #000000  chrome + cards
  //      HAIRLINE  = ohos_id_color_list_separator    #33182431 / #33ffffff
  //    -> grey = chrome (title bar + tab strip) and grey = section cards on a white canvas.
  //       Both boundaries are now actually visible, which is what removes the phantom gap.
  //    `ohos_id_card_background` / `ohos_id_card_list_item` / `ohos_id_color_accent` that
  //    ARKUI_UI_STANDARD.md §2.1 lists do NOT exist in this compileSdk 26.0.0 SDK (verified
  //    against ets/build-tools/ets-loader/sysResource.js), so only the `ohos_id_color_*`
  //    family is used.
  // 3) Tabs hugs its content: explicit barHeight(40), a bar background + 1px divider so the
  //    bar/content boundary is an explicit line, `fadingEdge(false)` so the default white
  //    fade gradient cannot bleach the grey bar, and the scroll column no longer adds a
  //    top offset -- the first card starts directly under the divider.

  @Builder
  rowLabel(label: ResourceStr) {
    Text(label)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_primary'))
  }

  @Builder
  rowCaption(label: ResourceStr) {
    Text(label)
      .fontSize(12)
      .fontColor($r('sys.color.ohos_id_color_text_hint'))
  }

  // Section caption: the group title inside a card. Kept as one builder so every group in
  // every tab has identical metrics (13vp / secondary / 12vp side inset).
  @Builder
  sectionCaption(label: ResourceStr) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 2 })
  }

  // Hairline between rows inside a card.
  @Builder
  rowDivider() {
    Divider()
      .color($r('sys.color.ohos_id_color_list_separator'))
      .margin({ left: 12, right: 12 })
  }

  @Builder
  switchRow(label: ResourceStr, value: boolean, onChange: (v: boolean) => void) {
    Row() {
      this.rowLabel(label)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: value })
        .onChange((checked: boolean) => {
          onChange(checked);
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
  }

  @Builder
  valueRow(label: ResourceStr, value: string) {
    Row() {
      this.rowLabel(label)
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
  }

  @Builder
  hotkeyRow(label: ResourceStr, desc: ResourceStr, keyText: string) {
    Row() {
      Column() {
        this.rowLabel(label)
        this.rowCaption(desc)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(keyText)
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
    .width('100%')
    .height(56)
    .padding({ left: 12, right: 12 })
  }

  // ---------------------------------------------------------------- tab bodies

  @Builder
  tabInput() {
    Scroll() {
      Column() {
        // ---- 候选组 ----
        Column() {
          this.sectionCaption($r('app.string.group_candidate'))

          Row() {
            this.rowLabel($r('app.string.set_page_size'))
            Blank()
            Text(`${this.pageSize}`)
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .margin({ right: 8 })
            Slider({ value: this.pageSize, min: 3, max: 9, step: 1, style: SliderStyle.OutSet })
              .width(120)
              .onChange((value: number) => {
                this.pageSize = value;
              })
          }
          .width('100%')
          .height(48)
          .padding({ left: 12, right: 12 })

          this.rowDivider()

          this.switchRow($r('app.string.set_sentence'), this.enableSentence, (v: boolean) => {
            this.enableSentence = v;
          })

          this.rowDivider()

          this.switchRow($r('app.string.set_completion'), this.enableCompletion, (v: boolean) => {
            this.enableCompletion = v;
          })
        }
        .width('100%')
        .margin({ bottom: 12 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

        // ---- 标点组 ----
        Column() {
          this.sectionCaption($r('app.string.group_punct'))

          this.switchRow($r('app.string.set_punct'), this.punct, (v: boolean) => {
            this.punct = v;
          })

          this.rowDivider()

          this.switchRow($r('app.string.set_ascii_punct'), this.asciiPunct, (v: boolean) => {
            this.asciiPunct = v;
          })

          this.rowDivider()

          this.switchRow($r('app.string.set_emoji'), this.emoji, (v: boolean) => {
            this.emoji = v;
          })
        }
        .width('100%')
        .margin({ bottom: 12 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

        // ---- 中英与简繁组 ----
        Column() {
          this.sectionCaption($r('app.string.group_mode'))

          this.switchRow($r('app.string.set_traditional'), this.traditional, (v: boolean) => {
            this.traditional = v;
          })
        }
        .width('100%')
        .margin({ bottom: 12 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      }
      // top: 8 -- a single small breathing step below the tab strip's divider (the card's own
      // caption adds its internal padding). No dead gap between the bar and the first card.
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  tabSchema() {
    Scroll() {
      Column() {
        Column() {
          this.sectionCaption($r('app.string.group_schema'))

          Row() {
            Select(this.schemaOptions())
              .value(schemaNameOf(this.schema))
              .onSelect((index: number) => {
                this.schema = this.schemas[index].id;
              })
          }
          .width('100%')
          .height(52)
          .padding({ left: 12, right: 12 })

          this.rowDivider()

          this.valueRow($r('app.string.set_current_schema'), schemaNameOf(this.schema))
        }
        .width('100%')
        .margin({ bottom: 12 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

        Column() {
          this.sectionCaption($r('app.string.group_hotkey'))

          this.hotkeyRow($r('app.string.set_hotkey_toggle'), $r('app.string.set_hotkey_toggle_desc'), 'Shift')

          this.rowDivider()

          this.hotkeyRow($r('app.string.set_hotkey_trad'), $r('app.string.set_hotkey_trad_desc'), 'Ctrl+Shift+4')

          this.rowDivider()

          this.hotkeyRow($r('app.string.set_hotkey_schema'), $r('app.string.set_hotkey_schema_desc'), 'Ctrl+Shift+9')
        }
        .width('100%')
        .margin({ bottom: 12 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  tabAbout() {
    Scroll() {
      Column() {
        Column() {
          this.sectionCaption($r('app.string.group_about'))

          this.valueRow($r('app.string.set_engine'), 'librime 1.17.0 + rime-ice + OpenCC')

          this.rowDivider()

          this.valueRow($r('app.string.set_config_path'), this.settingsPath)

          this.rowDivider()

          this.valueRow($r('app.string.set_switch_ime'), $r('app.string.set_switch').toString())
        }
        .width('100%')
        .margin({ bottom: 12 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

        // Destructive entry. Kept a standard `Button` (ARKUI_UI_STANDARD §1 forbids hand-rolled
        // Column+onClick rows) but painted with the SURFACE colour + a hairline border: the
        // previous `Button` used ohos_id_color_list_card_bg (= #ffffffff), i.e. exactly the
        // page colour, so the button was invisible. The second confirmation stays an
        // AlertDialog (§1 危险操作).
        Button($r('app.string.settings_reset'), { type: ButtonType.Normal })
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .height(48)
          .borderRadius(12)
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .border({ width: 1, color: $r('sys.color.ohos_id_color_list_separator') })
          .hoverEffect(HoverEffect.Highlight)
          .onClick(() => {
            this.confirmReset();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  tabBarItem(label: ResourceStr) {
    Text(label)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_primary'))
      .padding({ left: 8, right: 8 })
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.settings_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Button($r('app.string.settings_save'))
          .fontSize(15)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_hint'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      }

      Tabs({ barPosition: BarPosition.Start }) {
        TabContent() {
          this.tabInput()
        }.tabBar(this.tabBarItem($r('app.string.tab_input')))

        TabContent() {
          this.tabSchema()
        }.tabBar(this.tabBarItem($r('app.string.tab_schema')))

        TabContent() {
          this.tabAbout()
        }.tabBar(this.tabBarItem($r('app.string.tab_about')))
      }
      // Tabs hugging its content:
      //  * barHeight(40)     -- explicit, instead of the breakpoint-dependent default, so the
      //                         strip does not grow a tall empty band on 2in1;
      //  * barBackgroundColor(SURFACE) -- makes the strip a *visible* band distinct from the
      //                         white content canvas (before: white on white, invisible);
      //  * divider(...)      -- one explicit 1px line marking the bar/content boundary;
      //  * fadingEdge(false) -- the default white fade gradient would bleach the grey strip;
      //  * barMode(Fixed)    -- labels never shrink into an unreadable strip on narrow windows.
      .barMode(BarMode.Fixed)
      .barHeight(40)
      .barBackgroundColor($r('sys.color.ohos_id_color_sub_background'))
      .divider({ strokeWidth: 1, color: $r('sys.color.ohos_id_color_list_separator') })
      .fadingEdge(false)
      .width('100%')
      .layoutWeight(1)
      // Do NOT set .backgroundColor() on the Tabs itself.
      //
      // Measured on this image: the Tabs node paints its own background AFTER its children's
      // background fills but BEFORE their text, so any background set here silently hides both
      // `barBackgroundColor` and every card's `.backgroundColor()` underneath it -- the strip and
      // the section cards render pure white while their text still shows. RS still reports the
      // correct #F1F3F5 on those nodes, which is what makes it look like a layout bug rather than a
      // paint-order bug. The page canvas is already painted by the root Column below, so this
      // attribute is both redundant and destructive; leave it unset.
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
