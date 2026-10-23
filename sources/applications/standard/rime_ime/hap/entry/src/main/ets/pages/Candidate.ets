// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Independent candidate window (FLAG_CANDIDATE panel). No soft keyboard here: on a
 * machine with a physical keyboard nothing else ever shows up.
 *
 * Layout: one horizontal strip -- composing text, then the candidates of the current page.
 * The panel is only 56vp tall, so the candidates live in a horizontal Scroll; anything
 * beyond the page_size configured in the settings page simply scrolls.
 */
import { imeController } from '../model/ImeSingleton';

class RimeCandidateItem {
  t: string = '';
  c: string = '';
}

@Entry
@Component
struct Candidate {
  @StorageLink('rimeCandidates') rimeCandidates: RimeCandidateItem[] = [];
  @StorageLink('rimeInput') rimeInput: string = '';
  @StorageLink('rimeComposing') rimeComposing: boolean = false;

  private select(index: number): void {
    if (imeController !== undefined && imeController !== null) {
      imeController.selectCandidate(index);
    }
  }

  @Builder
  candidateRow(item: RimeCandidateItem, index: number) {
    Row() {
      Text(`${index + 1}`)
        .fontSize(12)
        .fontColor($r('sys.color.ohos_id_color_text_hint'))
        .margin({ right: 4 })
      Text(item.t)
        .fontSize(22)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
    }
    .height(48)
    .padding({ left: 10, right: 10 })
    .borderRadius(8)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.select(index);
    })
  }

  build() {
    Row() {
      if (this.rimeComposing) {
        Text(this.rimeInput)
          .fontSize(18)
          .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .margin({ left: 12, right: 12 })
        Divider()
          .vertical(true)
          .height(24)
          .color($r('sys.color.ohos_id_color_list_separator'))
        Scroll() {
          Row() {
            ForEach(this.rimeCandidates, (item: RimeCandidateItem, index: number) => {
              this.candidateRow(item, index)
            }, (item: RimeCandidateItem, index: number) => `${index}_${item.t}`)
          }
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(56)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .borderRadius(10)
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 2 })
  }
}