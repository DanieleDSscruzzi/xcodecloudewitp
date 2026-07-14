//
//  LocalizationCatalog.swift
//  WITP — le lingue del mondo (tutte quelle di sistema iOS).
//

import SwiftUI
import Combine
enum AppLanguage: String, CaseIterable, Identifiable {
    case it = "it"
    case en = "en"
    case en_GB = "en-GB"
    case en_AU = "en-AU"
    case es = "es"
    case es_419 = "es-419"
    case fr = "fr"
    case fr_CA = "fr-CA"
    case de = "de"
    case pt_BR = "pt-BR"
    case pt_PT = "pt-PT"
    case nl = "nl"
    case ru = "ru"
    case zh_Hans = "zh-Hans"
    case zh_Hant_TW = "zh-Hant-TW"
    case zh_Hant_HK = "zh-Hant-HK"
    case ja = "ja"
    case ko = "ko"
    case ar = "ar"
    case he = "he"
    case hi = "hi"
    case tr = "tr"
    case pl = "pl"
    case uk = "uk"
    case sv = "sv"
    case da = "da"
    case nb = "nb"
    case fi = "fi"
    case el = "el"
    case cs = "cs"
    case ro = "ro"
    case hu = "hu"
    case th = "th"
    case vi = "vi"
    case id = "id"
    case ca = "ca"
    case hr = "hr"
    case sk = "sk"
    case sl = "sl"
    case bg = "bg"
    case sr = "sr"
    case lt = "lt"
    case lv = "lv"
    case et = "et"
    case ms = "ms"
    case fil = "fil"
    // Aggiunte con iOS 26: lingue dell'India e del Sud-est asiatico
    case bn = "bn"
    case gu = "gu"
    case kn = "kn"
    case ml = "ml"
    case mr = "mr"
    case pa = "pa"
    case ta = "ta"
    case te = "te"
    case ur = "ur"
    case ne = "ne"
    case si = "si"
    case my = "my"
    case km = "km"
    case lo = "lo"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .it: return "Italiano"
        case .en: return "English (US)"
        case .en_GB: return "English (UK)"
        case .en_AU: return "English (Australia)"
        case .es: return "Español (España)"
        case .es_419: return "Español (Latinoamérica)"
        case .fr: return "Français"
        case .fr_CA: return "Français (Canada)"
        case .de: return "Deutsch"
        case .pt_BR: return "Português (Brasil)"
        case .pt_PT: return "Português (Portugal)"
        case .nl: return "Nederlands"
        case .ru: return "Русский"
        case .zh_Hans: return "简体中文"
        case .zh_Hant_TW: return "繁體中文（台灣）"
        case .zh_Hant_HK: return "繁體中文（香港）"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .ar: return "العربية"
        case .he: return "עברית"
        case .hi: return "हिन्दी"
        case .tr: return "Türkçe"
        case .pl: return "Polski"
        case .uk: return "Українська"
        case .sv: return "Svenska"
        case .da: return "Dansk"
        case .nb: return "Norsk bokmål"
        case .fi: return "Suomi"
        case .el: return "Ελληνικά"
        case .cs: return "Čeština"
        case .ro: return "Română"
        case .hu: return "Magyar"
        case .th: return "ไทย"
        case .vi: return "Tiếng Việt"
        case .id: return "Bahasa Indonesia"
        case .ca: return "Català"
        case .hr: return "Hrvatski"
        case .sk: return "Slovenčina"
        case .sl: return "Slovenščina"
        case .bg: return "Български"
        case .sr: return "Српски"
        case .lt: return "Lietuvių"
        case .lv: return "Latviešu"
        case .et: return "Eesti"
        case .ms: return "Bahasa Melayu"
        case .fil: return "Filipino"
        case .bn: return "বাংলা"
        case .gu: return "ગુજરાતી"
        case .kn: return "ಕನ್ನಡ"
        case .ml: return "മലയാളം"
        case .mr: return "मराठी"
        case .pa: return "ਪੰਜਾਬੀ"
        case .ta: return "தமிழ்"
        case .te: return "తెలుగు"
        case .ur: return "اردو"
        case .ne: return "नेपाली"
        case .si: return "සිංහල"
        case .my: return "မြန်မာ"
        case .km: return "ខ្មែរ"
        case .lo: return "ລາວ"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Lingue scritte da destra a sinistra.
    var isRTL: Bool { [.ar, .he, .ur].contains(self) }
}
@MainActor
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    private static let storageKey = "witp.language"

    /// "system" = segui la lingua di sistema; altrimenti un rawValue di AppLanguage.
    @Published var raw: String {
        didSet {
            UserDefaults.standard.set(raw, forKey: Self.storageKey)
        }
    }

    private init() {
        self.raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? "system"
    }

    var selected: AppLanguage? { raw == "system" ? nil : AppLanguage(rawValue: raw) }
    var localeOverride: Locale? { selected?.locale }
    var displayName: String { selected?.nativeName ?? "Automatica (sistema)" }
}
