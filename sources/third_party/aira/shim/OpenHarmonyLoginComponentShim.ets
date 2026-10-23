/**
 * [fix_aira_guide] OpenHarmony compatibility shim for the HMS-only
 * `@hms:core.account.LoginComponent` module (`loginComponentManager` +
 * `LoginWithHuaweiIDButton`).
 *
 * Why this file exists
 * -------------------
 * The upstream release HAP is compiled against the HarmonyOS SDK, where
 * `@kit.AccountKit` also re-exports `loginComponentManager` and the
 * `LoginWithHuaweiIDButton` ArkUI component. Neither of them exists on a plain
 * OpenHarmony build (pc_ptl / x86_64). A *static* named import of a missing
 * export is not a soft failure: when the page module is linked, the ArkCompiler
 * runtime throws
 *
 *   SyntaxError: the requested module '@hms:core.account.LoginComponent'
 *   does not provide an export name 'loginComponentManager'
 *
 * which aborts page construction. That is exactly what made the new-user
 * onboarding dead-end on pc_ptl: finishing the intro routes to
 * `app/pages/BrowserShellPage`, whose module link failed, the promise rejection
 * was swallowed by `finishOnboardingToBrowser()` (`.catch(() => undefined)`),
 * and the process was then killed by ArkUI with `reason=Js Error`.
 *
 * The fix mirrors the subset of the HMS API that the app actually uses, so the
 * call sites stay source-compatible, while every operation degrades to a
 * reported "unsupported" error instead of a module-link crash. HUAWEI ID sign-in
 * is therefore simply unavailable on OpenHarmony; every other feature (browser,
 * tabs, sync over WebDAV, ad blocking, downloads) is unaffected.
 */
import { BusinessError } from '@kit.BasicServicesKit';

/** Error code reported when a HUAWEI ID operation is requested on a platform without the HMS module. */
export const HUAWEI_LOGIN_UNSUPPORTED_CODE: number = 1001502009;

export namespace loginComponentManager {
  /** Mirrors the HMS `HuaweiIDCredential` shape; never produced by the shim. */
  export interface HuaweiIDCredential {
    readonly unionID: string;
    readonly openID: string;
    readonly authorizationCode: string;
    readonly idToken?: string;
  }

  /** Mirrors HMS `AgreementStatus`; values kept identical so the shim is drop-in. */
  export enum AgreementStatus {
    NOT_ACCEPTED = 0,
    ACCEPTED = 1
  }

  /** Mirrors HMS `Style`; only used to style the (unavailable) HUAWEI ID button. */
  export enum Style {
    BUTTON_RED = 0,
    BUTTON_WHITE = 1,
    BUTTON_WHITE_CIRCLE = 2,
    BUTTON_RED_CIRCLE = 3,
    BORDER_RED = 4,
    BORDER_WHITE = 5,
    WHITE_CIRCLE_BORDER = 6,
    CUSTOM = 7
  }

  /** Mirrors HMS `LoginType`. */
  export enum LoginType {
    ID = 0,
    PHONE = 1,
    QUICK_LOGIN = 2
  }

  /** Mirrors HMS `ClickEvent`. */
  export enum ClickEvent {
    CLICK = 0,
    CLICK_WITH_AGREEMENT = 1
  }

  function buildUnsupportedError(): BusinessError {
    const error: BusinessError = {
      code: HUAWEI_LOGIN_UNSUPPORTED_CODE,
      message: 'HUAWEI ID sign-in is unavailable on this platform (OpenHarmony build without HMS AccountKit).',
      name: 'BusinessError'
    };
    return error;
  }

  /**
   * Drop-in replacement for `loginComponentManager.LoginWithHuaweiIDButtonController`.
   * Every mutator returns `this` so existing fluent call sites keep working; the
   * registered click callback is fired with an "unsupported" BusinessError when
   * the fallback button built by `HuaweiLoginSheetContent` is pressed.
   */
  export class LoginWithHuaweiIDButtonController {
    private loginCallback?: (error: BusinessError, response: HuaweiIDCredential) => void;
    private clickEventCallback?: (error: BusinessError, response: ClickEvent) => void;
    private agreementStatus: AgreementStatus = AgreementStatus.NOT_ACCEPTED;
    private enabled: boolean = true;
    private locale: string = '';

    onClickLoginWithHuaweiIDButton(
      callback: (error: BusinessError, response: HuaweiIDCredential) => void
    ): LoginWithHuaweiIDButtonController {
      this.loginCallback = callback;
      return this;
    }

    onClickEvent(callback: (error: BusinessError, response: ClickEvent) => void): LoginWithHuaweiIDButtonController {
      this.clickEventCallback = callback;
      return this;
    }

    setAgreementStatus(agreementStatus: AgreementStatus): LoginWithHuaweiIDButtonController {
      this.agreementStatus = agreementStatus;
      return this;
    }

    setEnabled(enabled: boolean): LoginWithHuaweiIDButtonController {
      this.enabled = enabled;
      return this;
    }

    setLocale(locale: string): LoginWithHuaweiIDButtonController {
      this.locale = locale;
      return this;
    }

    getAgreementStatus(): AgreementStatus {
      return this.agreementStatus;
    }

    getEnabled(): boolean {
      return this.enabled;
    }

    getLocale(): string {
      return this.locale;
    }

    /**
     * [fix_aira_guide] Called by the ArkUI fallback button. Always reports the
     * "unsupported" failure so the surrounding sign-in flow unwinds through its
     * normal error path (toast + sheet close) instead of hanging.
     */
    notifyUnavailable(): void {
      const error: BusinessError = buildUnsupportedError();
      if (this.clickEventCallback !== undefined) {
        this.clickEventCallback(error, ClickEvent.CLICK);
      }
      if (this.loginCallback !== undefined) {
        this.loginCallback(error, {
          unionID: '',
          openID: '',
          authorizationCode: ''
        });
      }
    }
  }
}

/**
 * [fix_aira_guide] Always false on OpenHarmony: the HMS LoginComponent ArkUI
 * component is not part of the platform, so no code path may render it.
 */
export const IS_HUAWEI_LOGIN_COMPONENT_AVAILABLE: boolean = false;