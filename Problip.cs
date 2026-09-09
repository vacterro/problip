using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;
using System.Diagnostics;

// PROBLIP — persistent blip (meditation beeper).
// Single-source WinForms app; runtime companion assets are blip01.wav and
// problip.ico, loaded from beside the executable, so they ship with it.
// UI: saipen UI.md Golden Default. Text is NON-antialiased (pixel text).
// v3 C# rewrite. No TaskManager/ProcessExplorer — just a configurable beeper.

namespace Problip
{
    static class Native
    {
        [DllImport("gdi32.dll")] public static extern IntPtr CreateFont(int nHeight, int nWidth, int nEscapement, int nOrientation,
            int fnWeight, uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
            uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality, uint fdwPitchAndFamily, string lpszFace);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr handle);

        public const int WM_NCHITTEST = 0x84;
        public const int HTCAPTION = 2;
        public const int NONANTIALIASED_QUALITY = 3;
    }

    // One live palette projection. Every paint site reads the SAME static
    // Palette.BG / Palette.TEXT / ... properties, so switching a theme updates
    // exactly one object (Current) and the whole UI follows without threading a
    // theme through every DrawText/DrawButton call or recreating a single form.
    // Colors are instance fields, not statics: swapping Current is atomic enough
    // for a UI thread and cheap (one reference assignment per switch).
    class ProblipPalette
    {
        public Color BG;
        public Color SURFACE;
        public Color RAISED;
        public Color BEVEL;
        public Color BDARK;
        public Color LINK;       // accent (Android donor: Gold)
        public Color TEXT;
        public Color TEXT2;
        public Color MUTED;
        public Color COMPARE;
        public Color SUCCESS;
        public Color DANGERTXT;
        // Windows-only secondary slots. Derived from the donor palette in the
        // constructor so a themed session never mixes, say, a Dracula background
        // with a Golden Default slider fill (the ALT slot paints the volume
        // thumb) and no palette can forget to define them.
        public Color ALT;
        public ProblipPalette(Color bg, Color surface, Color raised, Color bevel, Color bdark,
                              Color link, Color text, Color text2, Color muted,
                              Color compare, Color success, Color dangerTxt)
        {
            BG = bg; SURFACE = surface; RAISED = raised; BEVEL = bevel; BDARK = bdark;
            LINK = link; TEXT = text; TEXT2 = text2; MUTED = muted;
            COMPARE = compare; SUCCESS = success; DANGERTXT = dangerTxt;
            // Deterministic midpoint between Surface and Raised: sits between
            // the two filled tones for every palette, so no theme is left with a
            // Golden Default slider fragment. For Golden Default this is the
            // derived 0x383226 (the former hard-coded 0x453D30 was a one-off
            // constant; the derived value keeps the same visual role).
            ALT = Color.FromArgb(
                (surface.R + raised.R) / 2,
                (surface.G + raised.G) / 2,
                (surface.B + raised.B) / 2);
        }
    }

    static class Palette
    {
        // The ONE current palette. Theme switching replaces this reference and
        // repaints the open windows; no other state moves.
        internal static ProblipPalette Current = ThemeModel.BuildClassicPalette();

        // Static projection kept for the ~50 existing paint sites. Golden
        // Default values are byte-identical to the previous hard-coded readonly
        // fields, so the pre-theme appearance is preserved exactly.
        public static Color BG        { get { return Current.BG; } }
        public static Color SURFACE   { get { return Current.SURFACE; } }
        public static Color RAISED    { get { return Current.RAISED; } }
        public static Color BEVEL     { get { return Current.BEVEL; } }
        public static Color BDARK     { get { return Current.BDARK; } }
        public static Color TEXT      { get { return Current.TEXT; } }
        public static Color TEXT2     { get { return Current.TEXT2; } }
        public static Color MUTED     { get { return Current.MUTED; } }
        public static Color COMPARE   { get { return Current.COMPARE; } }
        public static Color SUCCESS   { get { return Current.SUCCESS; } }
        public static Color DANGERTXT { get { return Current.DANGERTXT; } }
        public static Color ALT       { get { return Current.ALT; } }
        public static Color LINK      { get { return Current.LINK; } }
    }

    // The tray and window icon both come from problip.ico, whose frames are the
    // SAIPEN_OrangeShine avatar downscaled with NEAREST resampling (see
    // Scripts/make_pixel_ico.py) - strictly aliased, no antialiasing. Loading
    // the exact-size frame lets the shell show native pixels instead of
    // resampling a smooth image, so there is no blur at any DPI.
    // Registry Run-entry projection of the AutoStart setting. Centralized so it
    // can be unit-driven against an arbitrary key path (the app always passes the
    // real Run path) without the tests ever touching a developer's Run key, and
    // so the value is checked against this executable rather than merely tested
    // for existence -- a stale entry from a moved copy must not read as healthy.
    static class AutoStart
    {
        public const string ValueName = "Problip";
        public const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

        // Registry mutation is success only when the postcondition is verified:
        // Set re-reads the value and confirms it names this executable, Clear
        // confirms the value is gone. "No exception" was never proof that the
        // write landed; a failed mutation must be observable, not assumed.
        public static bool Set(string runKeyPath, string exePath)
        {
            try
            {
                using (RegistryKey rk = Registry.CurrentUser.CreateSubKey(runKeyPath))
                {
                    if (rk == null) return false;
                    rk.SetValue(ValueName, "\"" + exePath + "\"");
                }
                return IsEnabled(runKeyPath, exePath);
            }
            catch { return false; }
        }
        public static bool Clear(string runKeyPath)
        {
            try
            {
                using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(runKeyPath, true))
                {
                    if (rk != null) rk.DeleteValue(ValueName, false);
                }
                using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(runKeyPath))
                {
                    return rk == null || rk.GetValue(ValueName) == null;
                }
            }
            catch { return false; }
        }
        public static bool IsEnabled(string runKeyPath, string exePath)
        {
            try
            {
                using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(runKeyPath))
                {
                    if (rk == null) return false;
                    string val = rk.GetValue(ValueName) as string;
                    return val != null && val.Trim('"').Equals(exePath, StringComparison.OrdinalIgnoreCase);
                }
            }
            catch { return false; }
        }
    }

    static class AppIcon
    {
        public static Icon For(string path, int size)
        {
            try
            {
                if (path != null && File.Exists(path))
                    return new Icon(path, size, size);
            }
            catch { }
            using (Icon fallback = SystemIcons.Application) return (Icon)fallback.Clone();
        }
    }

    // Interval identity for the three scheduling modes. Range is the original
    // MinMs/MaxMs preset model; Manual is user FROM/TO seconds (1..3600); Pulse
    // alternates a fixed short slot with a fresh random long slot. Kept as a
    // plain enum on purpose: no strategy hierarchy, no per-mode subclasses.
    enum IntervalKind
    {
        Range,
        Manual,
        Pulse
    }

    class Settings
    {
        // Central defaults: Load() falls back to these for invalid input, and a
        // fresh install writes them to problip.ini. One place, no scattered magic.
        public const double DefaultVolume = 0.05;
        public const int DefaultMinMs = 4000;
        public const int DefaultMaxMs = 7000;
        public const int MinMsFloor = 1000;
        public const int MaxMsCeiling = 60000;
        // MANUAL bounds: user seconds, clamped into 1..3600 (donor semantics).
        public const int ManualSecFloor = 1;
        public const int ManualSecCeiling = 3600;
        public const int DefaultManualFromSec = 4;
        public const int DefaultManualToSec = 7;

        public string Dir;
        public string IniPath;
        public string WavPath;
        public string IcoPath;
        public double Volume = DefaultVolume;
        public int MinMs = DefaultMinMs;
        public int MaxMs = DefaultMaxMs;
        // The selected interval mode. Absent/malformed INI value => Range, so an
        // old problip.ini behaves exactly as before this field existed.
        public IntervalKind Kind = IntervalKind.Range;
        // MANUAL bounds in seconds. Malformed values fall back to 4/7; the
        // canonical order (FROM <= TO) is enforced by SanitizeManual.
        public int ManualFromSec = DefaultManualFromSec;
        public int ManualToSec = DefaultManualToSec;
        // Fresh installs start opt-in: a public build must not silently register
        // itself in the user's Run key on first launch. AutoStart=1 in an existing
        // problip.ini keeps working; the default only applies to absent state.
        public bool AutoStart = false;
        // User intent: whether a launch of Problip.exe should arm the periodic
        // beeper. Distinct from AutoStart (whether Windows launches the app at
        // login) and from engine health (whether the sound asset is playable);
        // a broken WAV while the user wanted ON must not rewrite this to 0.
        public bool RunOnLaunch = true;
        // Whether the compact "BLIPS n" total line is painted in the settings
        // window. Purely a visibility preference: hiding it never stops the
        // statistics from being recorded. Application setting, so it lives in
        // problip.ini -- never in the statistics file.
        public bool ShowBlipCounter = true;
        // Selected theme id (the catalog's stable persistence key). Absent or
        // malformed values normalize in memory to theme_classic (Golden Default),
        // so an old INI or a bad hand-edit can never leave the UI unthemed.
        public string ThemeId = ThemeModel.Classic.Id;
        // Whether a successful scheduled blip softly tints the main window with
        // the active accent. Absent/malformed INI value keeps the product default
        // (ON) -- only an exact "0" turns it off.
        public bool BlipGlow = true;

        public Settings(string dir)
        {
            Dir = dir;
            IniPath = Path.Combine(dir, "problip.ini");
            WavPath = Path.Combine(dir, "blip01.wav");
            IcoPath = Path.Combine(dir, "problip.ico");
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern int GetPrivateProfileString(string app, string key, string def, System.Text.StringBuilder buf, int size, string file);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern bool WritePrivateProfileString(string app, string key, string val, string file);

        string Read(string key, string def)
        {
            var sb = new System.Text.StringBuilder(260);
            GetPrivateProfileString("problip", key, def, sb, sb.Capacity, IniPath);
            return sb.ToString();
        }
        // Best-effort persistence: returns false instead of swallowing the Win32
        // result, so a write into a read-only/non-writable directory is observable
        // rather than silently presented as saved state.
        bool TryWrite(string key, string val)
        {
            try { return WritePrivateProfileString("problip", key, val, IniPath); }
            catch { return false; }
        }

        public void Load()
        {
            // Parse into temporaries: TryParse's out-value assignment used to
            // clobber fields with 0 on invalid text ("abc" -> Volume=0 instead of
            // the intended default), and only the winner was kept. Unparseable
            // input falls back to the central defaults; parseable but
            // out-of-range input clamps into the canonical range.
            string v;
            double vol;
            v = Read("Volume", DefaultVolume.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture));
            if (!double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out vol)
                || double.IsNaN(vol) || double.IsInfinity(vol))
                vol = DefaultVolume;
            Volume = Math.Max(0.0, Math.Min(1.0, vol));

            int mn, mx;
            v = Read("MinMs", DefaultMinMs.ToString());
            if (!int.TryParse(v, out mn)) mn = DefaultMinMs;
            mn = Math.Max(MinMsFloor, Math.Min(MaxMsCeiling, mn));
            v = Read("MaxMs", DefaultMaxMs.ToString());
            if (!int.TryParse(v, out mx)) mx = DefaultMaxMs;
            mx = Math.Max(MinMsFloor, Math.Min(MaxMsCeiling, mx));
            // Range invariant after individual clamps: Min <= Max, both legal.
            if (mn > mx) mx = mn;
            MinMs = mn;
            MaxMs = mx;

            Kind = IntervalModel.ParseKind(Read("IntervalKind", "range"));
            int mf, mt;
            v = Read("ManualFromSec", DefaultManualFromSec.ToString());
            if (!int.TryParse(v, out mf)) mf = DefaultManualFromSec;
            v = Read("ManualToSec", DefaultManualToSec.ToString());
            if (!int.TryParse(v, out mt)) mt = DefaultManualToSec;
            // Clamp into 1..3600 and reorder so FROM <= TO: a persisted 10/5 or a
            // 0/9999 typo must normalize instead of poisoning scheduling.
            int[] manual = IntervalModel.SanitizeManual(mf, mt);
            ManualFromSec = manual[0];
            ManualToSec = manual[1];

            AutoStart = Read("AutoStart", "0") == "1";
            // Absent key, malformed value, anything but "0" keeps the product
            // default (ON): an old INI without this key must behave exactly as
            // before, when every launch started the beeper.
            RunOnLaunch = Read("RunOnLaunch", "1") != "0";
            // Absent key keeps the product default (visible): a fresh install
            // shows the BLIPS total, and an old INI without the key behaves as
            // if the feature had always been on.
            ShowBlipCounter = Read("ShowBlipCounter", "1") != "0";
            // Theme: normalize ANY persisted value (absent, legacy, unknown,
            // malformed) through the catalog so Load always ends on a palette
            // that can actually render.
            ThemeId = ThemeModel.ById(Read("ThemeId", ThemeModel.Classic.Id)).Id;
            // Glow: default ON; only an exact "0" means off (same tolerance as
            // RunOnLaunch/ShowBlipCounter).
            BlipGlow = Read("BlipGlow", "1") != "0";
            if (!File.Exists(IniPath))
            {
                // Fresh-install: best-effort defaults. A read-only location simply
                // keeps the in-memory defaults; we do not fail to start over a
                // missing/locked INI.
                TryWrite("Volume", Volume.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture));
                TryWrite("MinMs", MinMs.ToString());
                TryWrite("MaxMs", MaxMs.ToString());
                // Fresh-install default: opt-in, not silently self-registering.
                TryWrite("AutoStart", "0");
                // Fresh-install default: launching PROBLIP starts the beeper.
                TryWrite("RunOnLaunch", "1");
                // Fresh-install default: the BLIPS total line is visible.
                TryWrite("ShowBlipCounter", "1");
                // Fresh-install interval defaults: the ordinary Range preset the
                // product has always started with, plus the Manual bounds.
                TryWrite("IntervalKind", "range");
                TryWrite("ManualFromSec", DefaultManualFromSec.ToString());
                TryWrite("ManualToSec", DefaultManualToSec.ToString());
                // Fresh-install appearance defaults: Golden Default, glow on.
                TryWrite("ThemeId", ThemeModel.Classic.Id);
                TryWrite("BlipGlow", "1");
            }
        }

        // Persists a key. Throws IOException if the write did not land, so callers
        // can keep the UI honest about a value that was never saved. Virtual so a
        // test can simulate a mid-transaction write failure without touching the
        // real Win32 path.
        public virtual void Save(string key, string val)
        {
            if (!TryWrite(key, val))
                throw new System.IO.IOException("failed to persist setting '" + key + "' to " + IniPath);
        }

        // One interval transaction: write every key in order; on the first
        // failure, best-effort restore the keys already written from the
        // previous values (same key order) and return false. The caller applies
        // nothing until this returns true, so the session never displays a mode
        // the INI rejected. Small and dedicated on purpose -- no generic
        // transaction framework.
        public bool SaveIntervalState(System.Collections.Generic.KeyValuePair<string, string>[] next,
                                      System.Collections.Generic.KeyValuePair<string, string>[] previous)
        {
            for (int i = 0; i < next.Length; i++)
            {
                try { Save(next[i].Key, next[i].Value); }
                catch (System.IO.IOException)
                {
                    for (int j = 0; j < i; j++)
                    {
                        try { Save(previous[j].Key, previous[j].Value); }
                        catch (System.IO.IOException) { }
                    }
                    return false;
                }
            }
            return true;
        }
    }

    // Pure interval-mode helpers: INI-kind parsing, MANUAL sanitization and the
    // PULSE slot constants. No I/O, no clock, no WinForms -- every method is
    // driven directly by regressions.
    static class IntervalModel
    {
        public const int PulseShortMs = 5000;      // fixed short slot
        public const int PulseLongMinMs = 10000;   // long slot is a fresh
        public const int PulseLongMaxMs = 20000;   // random 10..20 s

        // Absent => Range (old INIs keep current behavior); anything but the
        // exact mode words normalizes to Range rather than failing to load.
        public static IntervalKind ParseKind(string value)
        {
            string v = (value ?? "").Trim().ToLowerInvariant();
            if (v == "manual") return IntervalKind.Manual;
            if (v == "pulse") return IntervalKind.Pulse;
            return IntervalKind.Range;
        }

        public static string KindKey(IntervalKind kind)
        {
            return kind == IntervalKind.Manual ? "manual"
                 : kind == IntervalKind.Pulse ? "pulse"
                 : "range";
        }

        // Clamp each bound into 1..3600 and reorder so FROM <= TO. Returns a
        // fresh [from, to] array instead of using out parameters, so reflection
        // (PowerShell) can invoke it directly.
        public static int[] SanitizeManual(int fromSec, int toSec)
        {
            int f = ClampSec(fromSec);
            int t = ClampSec(toSec);
            if (f > t) { int tmp = f; f = t; t = tmp; }
            return new int[] { f, t };
        }

        public static int ClampSec(int sec)
        {
            if (sec < Settings.ManualSecFloor) return Settings.ManualSecFloor;
            if (sec > Settings.ManualSecCeiling) return Settings.ManualSecCeiling;
            return sec;
        }
    }

    // Theme identity + resolution. The fifteen Wintage palette designs and their
    // stable persistence IDs; ids never change, display names are presentation.
    // All fifteen are ordinary FREE Windows features: no ownership, no trial, no
    // entitlement layer -- only data identity is ported, nothing else.
    class ThemeEntry
    {
        public readonly string Id;
        public readonly string Name;
        public ThemeEntry(string id, string name) { Id = id; Name = name; }
    }

    static class ThemeModel
    {
        public static readonly ThemeEntry Classic      = new ThemeEntry("theme_classic", "Golden Default");
        public static readonly ThemeEntry Golden       = new ThemeEntry("theme_wintage_golden", "Dark Golden (Win95)");
        public static readonly ThemeEntry Claudecode   = new ThemeEntry("theme_wintage_claudecode", "Claude Code");
        public static readonly ThemeEntry Antigravity  = new ThemeEntry("theme_wintage_antigravity", "Antigravity");
        public static readonly ThemeEntry Klite        = new ThemeEntry("theme_wintage_klite", "K-Lite (MPC-HC)");
        public static readonly ThemeEntry Freebuff     = new ThemeEntry("theme_wintage_freebuff", "FreeBuff");
        public static readonly ThemeEntry Codenomad    = new ThemeEntry("theme_wintage_codenomad", "CodeNomad");
        public static readonly ThemeEntry Fpdefault    = new ThemeEntry("theme_wintage_fpdefault", "Default");
        public static readonly ThemeEntry Goldenvintage= new ThemeEntry("theme_wintage_goldenvintage", "Golden Vintage");
        public static readonly ThemeEntry Vintagedark  = new ThemeEntry("theme_wintage_vintagedark", "Vintage Dark");
        public static readonly ThemeEntry Vintageclassic = new ThemeEntry("theme_wintage_vintageclassic", "Vintage Classic");
        public static readonly ThemeEntry Oled         = new ThemeEntry("theme_wintage_oled", "Dark 2 (OLED)");
        public static readonly ThemeEntry Dracula      = new ThemeEntry("theme_wintage_dracula", "Dracula");
        public static readonly ThemeEntry Nord         = new ThemeEntry("theme_wintage_nord", "Nord");
        public static readonly ThemeEntry Solarized    = new ThemeEntry("theme_wintage_solarized", "Solarized Dark");

        // Themes-screen order (the donor's own order).
        public static readonly ThemeEntry[] All = new ThemeEntry[]
        {
            Classic, Golden, Claudecode, Antigravity, Klite, Freebuff, Codenomad,
            Fpdefault, Goldenvintage, Vintagedark, Vintageclassic, Oled, Dracula,
            Nord, Solarized
        };

        // Legacy mapping: the removed Custom palette duplicated Golden Default
        // exactly, so a stored theme_wintage_custom keeps working by resolving to
        // the same look instead of leaving an invisible selected theme.
        public static string Normalize(string id)
        {
            return id == "theme_wintage_custom" ? Classic.Id : id;
        }

        // Resolve ANY persisted value to a catalog entry. Unknown or null falls
        // back to Golden Default so an invalid stored theme can never leave the
        // UI partially themed or unthemed.
        public static ThemeEntry ById(string id)
        {
            string n = Normalize(id);
            if (n == null) return Classic;
            for (int i = 0; i < All.Length; i++)
                if (All[i].Id == n) return All[i];
            return Classic;
        }

        public static bool IsValidId(string id)
        {
            return ById(id).Id == Normalize(id) && IndexOf(id) >= 0;
        }

        static int IndexOf(string id)
        {
            if (id == null) return -1;
            for (int i = 0; i < All.Length; i++)
                if (All[i].Id == id) return i;
            return -1;
        }

        // True when the palette is the one LIGHT one (Vintage Classic: silver
        // surfaces, black text). Readability decisions can consult it.
        public static bool IsLight(ThemeEntry e) { return e == Vintageclassic; }

        // ---- The fifteen literal Wintage palettes (donor values, never improved).
        // Slot mapping from the donor: BG<-Bg, SURFACE<-Surface, RAISED<-Raised,
        // BEVEL<-Bevel, BDARK<-BDark, LINK<-Gold, TEXT<-TextMain, TEXT2<-TextDim,
        // MUTED<-Muted, COMPARE<-Compare, SUCCESS<-Success, DANGERTXT<-Danger.
        internal static ProblipPalette BuildClassicPalette()
        {
            return P(C(0x1A1810), C(0x332E22), C(0x3D372A), C(0x75663D), C(0x100E08),
                     C(0xF0D060), C(0xD4C89A), C(0x9C9371), C(0x6E674E), C(0x14120C),
                     C(0x4A7A20), C(0xD66464));
        }
        static ProblipPalette P(Color bg, Color surface, Color raised, Color bevel, Color bdark,
                                Color link, Color text, Color text2, Color muted,
                                Color compare, Color success, Color dangerTxt)
        {
            return new ProblipPalette(bg, surface, raised, bevel, bdark, link, text, text2,
                                      muted, compare, success, dangerTxt);
        }
        static Color C(int rgb)
        {
            return Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
        }

        static ProblipPalette PalGolden()         { return P(C(0x342012), C(0x4A341B), C(0x5A4324), C(0x826941), C(0x1C1208), C(0xD3B57A), C(0xE2CA95), C(0xC5AB6E), C(0x95804C), C(0x24170C), C(0x5B9630), C(0xD37676)); }
        static ProblipPalette PalClaudecode()     { return P(C(0x29241D), C(0x3B362A), C(0x484436), C(0x75644F), C(0x15130F), C(0xD1A27C), C(0xE0B997), C(0xC39870), C(0x93704E), C(0x1C1914), C(0x5B9630), C(0xD37575)); }
        static ProblipPalette PalAntigravity()    { return P(C(0x1B1F2C), C(0x272B3E), C(0x31354D), C(0x4B6678), C(0x0D0F17), C(0x7AD0D3), C(0x95DEE2), C(0x6EBFC5), C(0x4C8F95), C(0x12151E), C(0x5B9630), C(0xD06D6D)); }
        static ProblipPalette PalKlite()          { return P(C(0x212325), C(0x303235), C(0x3C3F42), C(0x5E6165), C(0x111213), C(0xA2A5AB), C(0xB8BABF), C(0x95989E), C(0x6D6F74), C(0x171819), C(0x5B9630), C(0xD27272)); }
        static ProblipPalette PalFreebuff()       { return P(C(0x1B232B), C(0x28303D), C(0x333B4B), C(0x506B5F), C(0x0E1116), C(0x89D37A), C(0xA0E295), C(0x7AC56E), C(0x55954C), C(0x13181D), C(0x5B9630), C(0xD27272)); }
        static ProblipPalette PalCodenomad()      { return P(C(0x1C242A), C(0x29313C), C(0x343D4A), C(0x575776), C(0x0E1216), C(0x9D86D1), C(0xB099DE), C(0x9C84C8), C(0x675091), C(0x13181D), C(0x5B9630), C(0xD27272)); }
        static ProblipPalette PalFpdefault()      { return P(C(0x1A1A1A), C(0x2B2B2B), C(0x343434), C(0x4E555B), C(0x0A0A0A), C(0x839BB0), C(0xC0C0C0), C(0x949494), C(0x656565), C(0x141414), C(0x4A7A20), C(0xDB7575)); }
        static ProblipPalette PalGoldenvintage()  { return P(C(0x0F0F0F), C(0x2B2B2B), C(0x333333), C(0x655E4A), C(0x050505), C(0xD6BE76), C(0xC4BA9F), C(0x8E8774), C(0x605C50), C(0x0B0B0B), C(0x4A7A20), C(0xD45C5C)); }
        static ProblipPalette PalVintagedark()    { return P(C(0x181818), C(0x2B2B2B), C(0x343434), C(0x4A5258), C(0x0A0A0A), C(0x738EA6), C(0xC0C0C0), C(0x8E8E8E), C(0x646464), C(0x121212), C(0x4A7A20), C(0xD45D5D)); }
        static ProblipPalette PalVintageclassic() { return P(C(0xC0C0C0), C(0xC0C0C0), C(0xD0D0D0), C(0xF6F6F6), C(0x808080), C(0xF6F6F6), C(0x000000), C(0x3A3A3A), C(0x6A6A6A), C(0xD0D0D0), C(0x4A7A20), C(0x7A2020)); }
        static ProblipPalette PalOled()           { return P(C(0x000000), C(0x0A0A0A), C(0x141414), C(0x5C5C5C), C(0x1A1A1A), C(0xFFFFFF), C(0xA0A0A0), C(0x777777), C(0x484848), C(0x000000), C(0x4A7A20), C(0xCE4444)); }
        static ProblipPalette PalDracula()        { return P(C(0x21222C), C(0x44475A), C(0x4C526D), C(0x706A9E), C(0x191A21), C(0xBD93F9), C(0xF8F8F2), C(0xB8B8B7), C(0x828285), C(0x191A21), C(0x4A7A20), C(0xDA7373)); }
        static ProblipPalette PalNord()           { return P(C(0x272C36), C(0x3B4252), C(0x3F4758), C(0x566C7D), C(0x232831), C(0x88C0D0), C(0xD8DEE9), C(0xA3A9B3), C(0x777C87), C(0x1D2129), C(0x4A7A20), C(0xDE8282)); }
        static ProblipPalette PalSolarized()      { return P(C(0x002B36), C(0x073642), C(0x1B444F), C(0x36667D), C(0x001F27), C(0x51A2DB), C(0x93A1A1), C(0x8D9EA1), C(0x426066), C(0x002029), C(0x4A7A20), C(0xDD7D7D)); }

        // id -> palette. Every catalog id has exactly one palette; anything else
        // resolves to Golden Default (same rule as ById).
        public static ProblipPalette PaletteFor(string id)
        {
            switch (Normalize(id))
            {
                case "theme_classic": return BuildClassicPalette();
                case "theme_wintage_golden": return PalGolden();
                case "theme_wintage_claudecode": return PalClaudecode();
                case "theme_wintage_antigravity": return PalAntigravity();
                case "theme_wintage_klite": return PalKlite();
                case "theme_wintage_freebuff": return PalFreebuff();
                case "theme_wintage_codenomad": return PalCodenomad();
                case "theme_wintage_fpdefault": return PalFpdefault();
                case "theme_wintage_goldenvintage": return PalGoldenvintage();
                case "theme_wintage_vintagedark": return PalVintagedark();
                case "theme_wintage_vintageclassic": return PalVintageclassic();
                case "theme_wintage_oled": return PalOled();
                case "theme_wintage_dracula": return PalDracula();
                case "theme_wintage_nord": return PalNord();
                case "theme_wintage_solarized": return PalSolarized();
                default: return BuildClassicPalette();
            }
        }
    }

    // Pure Blip Glow animation model (Android donor's scheduled-success signal):
    // a soft accent tint on the main window's background for ~260 ms. Timing
    // constants and alpha math live here -- NOT inside OnPaint branches -- so the
    // behavior is directly testable.
    static class GlowModel
    {
        public const double MaxAlpha = 0.25;   // a tint, never a flash
        public const int RiseMs = 60;          // linear rise to peak
        public const int DecayMs = 200;        // linear decay to zero
        public const int TotalMs = RiseMs + DecayMs;

        // alpha(t): 0..MaxAlpha. 0 at t<=0, linear rise to MaxAlpha at RiseMs,
        // linear decay to 0 at TotalMs, 0 afterwards. Never < 0, never > MaxAlpha.
        public static double Alpha(int elapsedMs)
        {
            if (elapsedMs <= 0) return 0.0;
            if (elapsedMs >= TotalMs) return 0.0;
            if (elapsedMs <= RiseMs) return MaxAlpha * elapsedMs / (double)RiseMs;
            int intoDecay = elapsedMs - RiseMs;
            return MaxAlpha * (1.0 - intoDecay / (double)DecayMs);
        }
    }
    // Secondary state, deliberately separate from problip.ini: a corrupt or
    // unwritable statistics file must never contaminate the user's playback
    // settings, and a statistics write failure must never break audio. The
    // mutation/calendar logic is pure and testable; only BlipStatsStore touches
    // the filesystem.
    class BlipStatsRecord
    {
        public string DayKey;
        public long TodayCount;
        public string WeekKey;
        public long WeekCount;
        public string MonthKey;
        public long MonthCount;
        public long TotalCount;
    }

    class BlipStatsSnapshot
    {
        public long Today;
        public long Week;
        public long Month;
        public long Total;
    }

    // Pure calendar + counter logic. No I/O, no WinForms, no clock of its own:
    // every method takes the wall-clock instant so a regression can inject
    // exact dates. Period keys use LOCAL calendar time; the week key is a
    // correct ISO-8601 week-year, never Year+weekNumber.
    static class BlipStatsLogic
    {
        // Saturating increment: malformed negative persisted counts normalize
        // to 0 first, long.MaxValue stays saturated, and ordinary values add
        // one. No wraparound to a negative UI counter is possible.
        public static long IncrementSaturating(long value)
        {
            if (value < 0) value = 0;
            if (value == long.MaxValue) return long.MaxValue;
            return value + 1;
        }

        // Persisted counts are sanitized on read and before display.
        public static long Sanitize(long value)
        {
            return value < 0 ? 0 : value;
        }

        public static string DayKey(DateTime now)
        {
            return now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        }

        public static string MonthKey(DateTime now)
        {
            return now.ToString("yyyy-MM", System.Globalization.CultureInfo.InvariantCulture);
        }

        // ISO-8601 week: Monday is the first day, week 1 is the week with at
        // least four days, and the week-YEAR is the calendar year of the
        // Thursday in that week. Around New Year a date can belong to the
        // adjacent week-year, which is why "Year + weekNumber" is wrong.
        public static string WeekKey(DateTime now)
        {
            int weekYear, week;
            IsoWeek(now, out weekYear, out week);
            return weekYear.ToString("0000", System.Globalization.CultureInfo.InvariantCulture)
                + "-W" + week.ToString("00", System.Globalization.CultureInfo.InvariantCulture);
        }

        public static void IsoWeek(DateTime now, out int weekYear, out int week)
        {
            DateTime date = now.Date;
            // Monday = 0 ... Sunday = 6.
            int mondayIndex = ((int)date.DayOfWeek + 6) % 7;
            // The Thursday of this ISO week decides the week-year.
            DateTime thursday = date.AddDays(3 - mondayIndex);
            weekYear = thursday.Year;
            week = 1 + (thursday.DayOfYear - 1) / 7;
        }

        // Displays stored state for the CURRENT instant without mutating it:
        // stale periods read 0 even before the first blip of the new period
        // (lazy rollover, no midnight timer), Total never resets.
        public static BlipStatsSnapshot Snapshot(BlipStatsRecord r, DateTime now)
        {
            string day = DayKey(now), week = WeekKey(now), month = MonthKey(now);
            BlipStatsSnapshot s = new BlipStatsSnapshot();
            s.Today = r.DayKey == day ? Sanitize(r.TodayCount) : 0;
            s.Week = r.WeekKey == week ? Sanitize(r.WeekCount) : 0;
            s.Month = r.MonthKey == month ? Sanitize(r.MonthCount) : 0;
            s.Total = Sanitize(r.TotalCount);
            return s;
        }

        // Records exactly one successful scheduled blip: a new period starts at
        // 1, an unchanged period increments, Total always increments.
        public static void Record(BlipStatsRecord r, DateTime now)
        {
            string day = DayKey(now), week = WeekKey(now), month = MonthKey(now);
            if (r.DayKey != day) { r.DayKey = day; r.TodayCount = 1; }
            else r.TodayCount = IncrementSaturating(r.TodayCount);
            if (r.WeekKey != week) { r.WeekKey = week; r.WeekCount = 1; }
            else r.WeekCount = IncrementSaturating(r.WeekCount);
            if (r.MonthKey != month) { r.MonthKey = month; r.MonthCount = 1; }
            else r.MonthCount = IncrementSaturating(r.MonthCount);
            r.TotalCount = IncrementSaturating(r.TotalCount);
        }
    }

    // Durable, isolated statistics store. In-memory state is authoritative for
    // the process; writes are bounded (a tiny dirty/batching contract) and are
    // strictly best-effort: Flush() never throws, and a failed write leaves the
    // dirty flag set so the newest snapshot is retried on the next flush.
    //
    // SNAPSHOT COMMIT: the store used to persist seven keys one
    // WritePrivateProfileString call at a time, so a crash mid-Flush could
    // leave DayKey new but TodayCount old -- next launch presented yesterday's
    // count as today's. The whole [stats] section is now serialized to text,
    // written to a sibling temporary file, and committed to problip.stats.ini
    // only after the temporary write fully succeeds: a reader can only ever
    // see one COMPLETE snapshot, never a hybrid. A tiny managed parser reads
    // the section back; no Win32 profile call touches this file anymore.
    class BlipStatsStore
    {
        public const long FlushIntervalMs = 10000;

        public string Path;
        public BlipStatsRecord Record = new BlipStatsRecord();
        // Wall-clock calendar seam. Production: DateTime.Now. NEVER used for
        // interval scheduling (that is BlipEngine.NowMs).
        internal Func<DateTime> LocalNow = () => DateTime.Now;
        // Monotonic clock for bounded flushing only. Its own Stopwatch lifetime.
        readonly System.Diagnostics.Stopwatch Clock = System.Diagnostics.Stopwatch.StartNew();
        internal Func<long> NowMs;
        // The last SUCCESSFUL flush: clears the batching window.
        long LastFlushMs;
        // The last flush ATTEMPT, successful or not. The old contract advanced
        // the window only on success, so a permanently unwritable stats path
        // retried a synchronous disk operation on EVERY blip -- at a 1-second
        // MANUAL interval that is one failed disk hit per second inside the
        // scheduled path. Attempt time now advances on failure too, bounding
        // retries to the batching interval regardless of outcome.
        long LastFlushAttemptMs;
        public bool Dirty;
        // Test instrumentation only: one per actual persistent snapshot commit
        // attempt (never per key -- the commit is one operation now).
        internal int FlushAttemptCount;

        // Commit seam for the atomic regression: production replaces the
        // temporary file over the target. A test can force the replacement
        // step to fail before the committed file is touched.
        internal Func<string, string, bool> CommitFile = DefaultCommitFile;

        // Same-directory atomic replacement. WritePrivateProfileString has no
        // transactional equivalent, so the commit is File.Replace when the
        // target already exists (same-volume atomic swap, keeps no backup) and
        // File.Move when it does not. A Move/Replace failure leaves the
        // committed file untouched.
        static bool DefaultCommitFile(string tempPath, string targetPath)
        {
            try
            {
                if (System.IO.File.Exists(targetPath))
                    System.IO.File.Replace(tempPath, targetPath, null);
                else
                    System.IO.File.Move(tempPath, targetPath);
                return true;
            }
            catch { return false; }
        }

        public BlipStatsStore(string dir)
        {
            Path = System.IO.Path.Combine(dir, "problip.stats.ini");
            NowMs = () => Clock.ElapsedMilliseconds;
            Load();
        }

        public BlipStatsSnapshot Snapshot()
        {
            return BlipStatsLogic.Snapshot(Record, LocalNow());
        }

        // One successful scheduled blip: update memory, mark dirty, and attempt
        // a flush at most once per FlushIntervalMs -- counted from the last
        // ATTEMPT, so a failing stats path cannot turn every blip into a
        // synchronous disk failure. A flush failure is swallowed here on
        // purpose -- statistics are secondary and must never surface into the
        // audio path.
        public void RecordBlip()
        {
            BlipStatsLogic.Record(Record, LocalNow());
            Dirty = true;
            if (NowMs() - LastFlushAttemptMs >= FlushIntervalMs) Flush();
        }

        // Best-effort write of the newest in-memory snapshot. Returns whether it
        // landed; never throws. On success the dirty flag clears and the
        // batching window resets; on failure the committed file stays on the
        // previous COMPLETE snapshot, the temp file is removed best-effort,
        // Dirty stays set and the attempt window still advances (bounded retry).
        public bool Flush()
        {
            FlushAttemptCount++;
            LastFlushAttemptMs = NowMs();
            string temp = null;
            try
            {
                temp = Path + ".tmp";
                System.IO.File.WriteAllText(temp, Serialize(Record));
                if (!CommitFile(temp, Path)) return false;
                temp = null;                       // committed: nothing to clean up
                Dirty = false;
                LastFlushMs = NowMs();
                return true;
            }
            catch { return false; }
            finally
            {
                if (temp != null) { try { if (System.IO.File.Exists(temp)) System.IO.File.Delete(temp); } catch { } }
            }
        }

        // The complete [stats] section as one text block. This exact string is
        // the atomic unit on disk: readers see all of it or none of it.
        static string Serialize(BlipStatsRecord r)
        {
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            return "[stats]\r\n"
                + "DayKey=" + (r.DayKey ?? "") + "\r\n"
                + "TodayCount=" + BlipStatsLogic.Sanitize(r.TodayCount).ToString(inv) + "\r\n"
                + "WeekKey=" + (r.WeekKey ?? "") + "\r\n"
                + "WeekCount=" + BlipStatsLogic.Sanitize(r.WeekCount).ToString(inv) + "\r\n"
                + "MonthKey=" + (r.MonthKey ?? "") + "\r\n"
                + "MonthCount=" + BlipStatsLogic.Sanitize(r.MonthCount).ToString(inv) + "\r\n"
                + "TotalCount=" + BlipStatsLogic.Sanitize(r.TotalCount).ToString(inv) + "\r\n";
        }

        // Flush only when there is unpersisted state. Used on Stop and exit --
        // an explicit lifecycle flush is allowed to ignore the batching window
        // (a Stop 3 s after a failed automatic attempt must still try once
        // more, not skip the final write).
        public bool FlushIfDirty()
        {
            if (!Dirty) return true;
            return Flush();
        }

        void Load()
        {
            try
            {
                BlipStatsRecord r = new BlipStatsRecord();
                Dictionary<string, string> kv = ParseIniText(ReadAllTextBestEffort(Path));
                r.DayKey = Get(kv, "DayKey");
                r.TodayCount = SanitizeCount(kv, "TodayCount");
                r.WeekKey = Get(kv, "WeekKey");
                r.WeekCount = SanitizeCount(kv, "WeekCount");
                r.MonthKey = Get(kv, "MonthKey");
                r.MonthCount = SanitizeCount(kv, "MonthCount");
                r.TotalCount = SanitizeCount(kv, "TotalCount");
                Record = r;
            }
            catch
            {
                Record = new BlipStatsRecord();
            }
            Dirty = false;
        }

        // Minimal managed INI reader for THIS file's single [stats] section.
        // Accepts the section header case-insensitively, takes only keys inside
        // it, trims exactly one optional inline comment after the value, and
        // ignores blank/garbage lines -- the same tolerance the Win32 profile
        // API gave malformed hand-edited files.
        static Dictionary<string, string> ParseIniText(string text)
        {
            Dictionary<string, string> kv = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (text == null) return kv;
            bool inSection = false;
            foreach (string raw in text.Split(new char[] { '\r', '\n' }))
            {
                string line = raw.Trim();
                if (line.Length == 0) continue;
                if (line.StartsWith("[", StringComparison.Ordinal))
                {
                    inSection = line.Equals("[stats]", StringComparison.OrdinalIgnoreCase);
                    continue;
                }
                if (!inSection) continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string key = line.Substring(0, eq).Trim();
                string val = line.Substring(eq + 1).Trim();
                // One optional inline comment: "42 ; note" keeps 42, but a URL
                // or a value containing " ;" only loses the tail after " ;".
                int sep = val.IndexOf(" ;", StringComparison.Ordinal);
                if (sep >= 0) val = val.Substring(0, sep).Trim();
                kv[key] = val;
            }
            return kv;
        }

        static string ReadAllTextBestEffort(string target)
        {
            try
            {
                if (System.IO.File.Exists(target)) return System.IO.File.ReadAllText(target);
            }
            catch { }
            return "";
        }

        static string Get(Dictionary<string, string> kv, string key)
        {
            string v;
            return kv.TryGetValue(key, out v) ? v : "";
        }

        static long SanitizeCount(Dictionary<string, string> kv, string key)
        {
            long v;
            if (!long.TryParse(Get(kv, key), System.Globalization.NumberStyles.Integer,
                    System.Globalization.CultureInfo.InvariantCulture, out v))
                v = 0;
            return BlipStatsLogic.Sanitize(v);
        }
    }

    // Blip engine: plays a volume-scaled WAV on a jittered interval.
    class BlipEngine
    {
        Settings S;
        SoundPlayer Player;
        string CachePath;
        Random Rng = new Random();
        System.Windows.Forms.Timer Timer;
        // The one monotonic clock for scheduling and countdown preservation: a
        // single process-lifetime Stopwatch, started once and read many times.
        // The previous body constructed a NEW Stopwatch inside every NowMs()
        // call and read it immediately, so production time stayed ~0 forever:
        // LastPlayMs stalled, every scheduled tick after the first was
        // suppressed, and NextDueMs never aged. Tests inject a fake advancing
        // watch so a slow cache rebuild is simulated, never slept.
        readonly System.Diagnostics.Stopwatch Clock = System.Diagnostics.Stopwatch.StartNew();
        internal Func<long> NowMs;
        // The absolute due time of the currently armed wait. The one piece of
        // schedule state a cache reload needs: a volume change must preserve the
        // remaining wait (consuming any rebuild time), while an interval change
        // intentionally re-draws it.
        long NextDueMs;
        public bool Enabled = false;
        public int MinMs, MaxMs;
        // Interval identity. ManualMinMs/ManualMaxMs are the MANUAL bounds already
        // resolved to milliseconds for scheduling; MinMs/MaxMs stay the ordinary
        // Range values even while another mode is selected, so switching back to
        // a preset never re-derives anything.
        public IntervalKind Kind = IntervalKind.Range;
        public int ManualMinMs, ManualMaxMs;
        // PULSE session phase: true when the next long slot is preceded by the
        // fixed short one. Deliberately NOT persisted -- a session state, reset
        // on the transitions the product defines (new Start, Stop, switching
        // into/out of Pulse), untouched by volume/preview/flush noise.
        internal bool PulseShortNext = true;
        // Test instrumentation only: how many times NextDelay() has drawn a new
        // delay. A theme switch must never draw one (pure visual setting), so a
        // regression pins IntervalDrawCount before/after the switch.
        internal int IntervalDrawCount;
        // Random seam: production backs it with the existing Random; tests
        // script values. ONE source of randomness for range, manual and the
        // PULSE long slot -- never two independent implementations.
        internal Func<int, int, int> RandomInclusive = (min, max) => 0;
        // How many preview blips were requested. The observable a regression can
        // count without a microphone.
        public int PreviewCount;
        // How many SCHEDULED ticks reached a successful PlayNow() inside Tick.
        // Incremented only by the scheduled path — previews never touch it — so
        // a regression can prove periodic playback really happened, not merely
        // that Tick re-armed the timer.
        internal int ScheduledPlayCount;
        // Why the sound could not be loaded, or null when it is playable. A
        // failed load used to collapse to `Player = null` with nothing recorded,
        // while Start() still reported the engine as running -- so a missing or
        // corrupt blip01.wav was an indistinguishable silent no-op.
        public string LoadError;

        // Fired once per observable state transition (ON/OFF/ERR), never per
        // harmless tick. The tray and any open settings window subscribe so a
        // mid-wait playback failure is visible without a user click.
        public event EventHandler StateChanged;

        // The ONE successful-blip signal: raised only after a scheduled Tick's
        // PlayNow() succeeds. Preview()/TEST/failed playback never raise it. It
        // is the reusable seam for statistics now and optional Blip Glow later;
        // no event bus, no extra dependency.
        public event EventHandler BlipPlayed;

        void NotifyStateChanged()
        {
            var h = StateChanged;
            if (h != null) h(this, EventArgs.Empty);
        }

        void RaiseBlipPlayed()
        {
            var h = BlipPlayed;
            if (h != null) h(this, EventArgs.Empty);
        }

        // Local successful-blip statistics. Separate store/file; in-memory
        // authoritative; failures never surface into the audio path.
        public BlipStatsStore Stats;

        public BlipEngine(Settings s)
        {
            S = s;
            MinMs = s.MinMs;
            MaxMs = s.MaxMs;
            Kind = s.Kind;
            ManualMinMs = s.ManualFromSec * 1000;
            ManualMaxMs = s.ManualToSec * 1000;
            NowMs = () => Clock.ElapsedMilliseconds;
            RandomInclusive = (min, max) => Rng.Next(min, max + 1);
            Stats = new BlipStatsStore(s.Dir);
            Timer = new System.Windows.Forms.Timer();
            Timer.Tick += Tick;
            BuildCache();
        }

        void BuildCache()
        {
            string previous = CachePath;
            try
            {
                byte[] src = File.ReadAllBytes(S.WavPath);
                // SoundPlayer.Load() accepts arbitrary bytes -- it only reads the
                // stream -- and the format is not rejected until winmm tries to
                // play it, inside a per-tick catch. So the asset is validated
                // here, where the failure can still be reported.
                WavInfo info = ParseWav(src);
                byte[] scaled = ScaleWav(src, info, S.Volume);
                CachePath = Path.Combine(Path.GetTempPath(), "problip_" + Guid.NewGuid().ToString("N") + ".wav");
                File.WriteAllBytes(CachePath, scaled);
                if (Player != null) Player.Dispose();
                Player = new SoundPlayer(CachePath);
                Player.Load();
                LoadError = null;
            }
            catch (Exception ex)
            {
                if (Player != null) { try { Player.Dispose(); } catch { } }
                Player = null;
                LoadError = ex.Message;
            }
            // Deterministic test seam (tests\\runstate contract): a regression
            // simulates a slow rebuild by advancing its fake clock here, so the
            // re-armed countdown can be proven to consume build time. Production
            // leaves it null -- no cost, no behavior change.
            if (BuildDelaySim != null) { try { BuildDelaySim(); } catch { } }
            // Every volume change rebuilds the cache. Without this the old temp
            // WAV stays in %TEMP% for good, one file per drag, forever.
            if (previous != null && previous != CachePath)
            {
                try { if (File.Exists(previous)) File.Delete(previous); } catch { }
            }
        }

        // One authoritative WAV description. ParseWav fills it; ScaleWav and the
        // cache build consume it. No second chunk scan exists anywhere.
        internal struct WavInfo
        {
            public int BitsPerSample;
            public int Channels;
            public int SampleRate;
            public int BlockAlign;
            public int DataStart;
            public int DataLength;
        }

        // Parses AND validates the RIFF/WAVE container in one pass and returns the
        // metadata ScaleWav needs. Throws with a readable reason unless the bytes
        // are a file this app can scale: integer PCM (format tag 1), 8/16/24/32
        // bits per sample, internally consistent PCM frame metadata, non-empty
        // data, and chunk bounds that stay inside the DECLARED RIFF container
        // under checked arithmetic. The old split (RequireWav + a second scanner
        // in ScaleWav) let the two disagree; this is the only source of truth.
        //
        // The RIFF size field at bytes 4..7 is treated as authoritative: the
        // parser walks chunks only up to riffEnd = 8 + riffSize and never to
        // b.Length, so physical bytes beyond the declared container are ignored,
        // never parsed as WAVE chunks.
        static WavInfo ParseWav(byte[] b)
        {
            if (b.Length < 44
                || System.Text.Encoding.ASCII.GetString(b, 0, 4) != "RIFF"
                || System.Text.Encoding.ASCII.GetString(b, 8, 4) != "WAVE")
                throw new InvalidDataException("not a RIFF/WAVE file");
            // RIFF container bounds, overflow-safe: riffSize is unsigned and
            // riffEnd = 8 + riffSize must land inside the physical buffer.
            uint riffSize = BitConverter.ToUInt32(b, 4);
            if (riffSize < 4)
                throw new InvalidDataException("invalid RIFF container size");
            long riffEnd = 8L + riffSize;
            if (riffEnd > b.Length)
                throw new InvalidDataException("RIFF size exceeds the physical file");
            WavInfo info = new WavInfo();
            bool fmt = false, data = false;
            int frameBytes = 0;
            long pos = 12;
            // PROBLIP's contract: fmt must precede the data chunk used for
            // playback, exactly one PCM fmt, exactly one data chunk. A data chunk
            // before fmt, a duplicate fmt, or a container that cannot hold the
            // needed chunks is rejected rather than accidentally accepted.
            while (pos + 8 <= riffEnd)
            {
                string id = System.Text.Encoding.ASCII.GetString(b, (int)pos, 4);
                int len = BitConverter.ToInt32(b, (int)pos + 4);
                if (len < 0 || pos + 8 + (long)len > riffEnd)
                    throw new InvalidDataException("invalid WAV chunk layout");
                // An odd-sized chunk's pad byte must also lie inside the declared
                // container; a pad that spills past riffEnd is malformed.
                if ((len & 1) != 0 && pos + 8 + (long)len + 1 > riffEnd)
                    throw new InvalidDataException("WAV chunk padding lies outside the RIFF container");
                if (id == "fmt ")
                {
                    if (fmt) throw new InvalidDataException("multiple fmt chunks");
                    if (len < 16) throw new InvalidDataException("invalid WAV chunk layout");
                    int tag = BitConverter.ToUInt16(b, (int)pos + 8);
                    int channels = BitConverter.ToUInt16(b, (int)pos + 10);
                    int rate = BitConverter.ToInt32(b, (int)pos + 12);
                    int byteRate = BitConverter.ToInt32(b, (int)pos + 16);
                    int blockAlign = BitConverter.ToUInt16(b, (int)pos + 20);
                    int bits = BitConverter.ToUInt16(b, (int)pos + 22);
                    if (tag != 1) throw new InvalidDataException("unsupported WAV encoding");
                    if (channels < 1 || channels > 32) throw new InvalidDataException("unsupported WAV encoding");
                    if (bits != 8 && bits != 16 && bits != 24 && bits != 32)
                        throw new InvalidDataException("unsupported bits per sample");
                    // Integer PCM frames must be internally consistent, not
                    // merely "large enough": every frame is channels * bytes
                    // wide, byteRate is that per second, and data holds whole
                    // frames. frameBytes is bounded (<= 32 * 4 = 128); rate is
                    // not, so the product is compared in long, never int.
                    frameBytes = channels * (bits / 8);
                    if (blockAlign != frameBytes)
                        throw new InvalidDataException("invalid WAV chunk layout");
                    if (rate <= 0)
                        throw new InvalidDataException("invalid WAV chunk layout");
                    if (byteRate != (long)rate * blockAlign)
                        throw new InvalidDataException("invalid WAV chunk layout");
                    info.BitsPerSample = bits;
                    info.Channels = channels;
                    info.SampleRate = rate;
                    info.BlockAlign = blockAlign;
                    fmt = true;
                }
                else if (id == "data")
                {
                    if (!fmt) throw new InvalidDataException("data chunk before fmt chunk");
                    if (len <= 0) throw new InvalidDataException("WAVE file has no audio data");
                    info.DataStart = (int)pos + 8;
                    info.DataLength = len;
                    data = true;
                }
                if (fmt && data)
                {
                    if (frameBytes > 0 && info.DataLength % frameBytes != 0)
                        throw new InvalidDataException("invalid WAV chunk layout");
                    return info;
                }
                pos += 8 + len + (len & 1);
            }
            throw new InvalidDataException(fmt ? "WAVE file has no audio data" : "WAVE file has no format chunk");
        }

        // Scales the PCM samples in src using the metadata from ParseWav. It does
        // NOT re-scan the chunks: the data location and bit depth come from info.
        // bps can never be 0 here: ParseWav admitted only 8/16/24/32-bit PCM, so
        // the loop always advances and can never spin forever on 4-bit or float
        // input.
        byte[] ScaleWav(byte[] b, WavInfo info, double gain)
        {
            if (gain >= 0.999999) return b;
            byte[] outb = (byte[])b.Clone();
            int bps = info.BitsPerSample / 8;
            if (bps <= 0) throw new InvalidDataException("unsupported bits per sample");
            int dataStart = info.DataStart, dataLen = info.DataLength;
            int end = dataStart + dataLen;
            int bits = info.BitsPerSample;
            for (int i = dataStart; i + bps <= end; i += bps)
            {
                if (bits == 8)
                {
                    int v = (int)Math.Round((outb[i] - 128) * gain) + 128;
                    outb[i] = (byte)Math.Max(0, Math.Min(255, v));
                }
                else if (bits == 16)
                {
                    short v = BitConverter.ToInt16(outb, i);
                    int n = (int)Math.Round(v * gain);
                    if (n > 32767) n = 32767; else if (n < -32768) n = -32768;
                    outb[i] = (byte)(n & 0xFF); outb[i + 1] = (byte)((n >> 8) & 0xFF);
                }
                else if (bits == 24)
                {
                    int raw = outb[i] | (outb[i + 1] << 8) | (outb[i + 2] << 16);
                    int v = (raw & 0x800000) != 0 ? raw - 0x1000000 : raw;
                    int n = (int)Math.Round(v * gain);
                    if (n > 8388607) n = 8388607; else if (n < -8388608) n = -8388608;
                    n &= 0xFFFFFF;
                    outb[i] = (byte)(n & 0xFF); outb[i + 1] = (byte)((n >> 8) & 0xFF); outb[i + 2] = (byte)((n >> 16) & 0xFF);
                }
                else if (bits == 32)
                {
                    int v = BitConverter.ToInt32(outb, i);
                    long n = (long)Math.Round((double)v * gain);
                    if (n > int.MaxValue) n = int.MaxValue; else if (n < int.MinValue) n = int.MinValue;
                    byte[] tmp = BitConverter.GetBytes((int)n);
                    outb[i] = tmp[0]; outb[i + 1] = tmp[1]; outb[i + 2] = tmp[2]; outb[i + 3] = tmp[3];
                }
            }
            return outb;
        }

        int NextDelay()
        {
            IntervalDrawCount++;
            if (Kind == IntervalKind.Manual)
            {
                if (ManualMinMs >= ManualMaxMs) return ManualMinMs;
                return RandomInclusive(ManualMinMs, ManualMaxMs);
            }
            if (Kind == IntervalKind.Pulse)
            {
                // Alternate forever: short slot fixed, long slot a FRESH random
                // draw each time. The phase toggle lives here so every consumer
                // (Start, Tick re-arm, SetInterval re-arm) shares one contract.
                int delay;
                if (PulseShortNext) delay = IntervalModel.PulseShortMs;
                else delay = RandomInclusive(IntervalModel.PulseLongMinMs, IntervalModel.PulseLongMaxMs);
                PulseShortNext = !PulseShortNext;
                return delay;
            }
            if (MinMs >= MaxMs) return MinMs;
            return RandomInclusive(MinMs, MaxMs);
        }

        // The single timer contract. Every arming goes through here so the
        // Interval on the timer and the schedule state (NextDueMs) can never
        // disagree, and so a reload can read back the remaining wait.
        void ArmTimer(int delay)
        {
            if (delay < 1) delay = 1;
            NextDueMs = NowMs() + delay;
            Timer.Interval = delay;
        }

        // Remaining wait on the currently armed schedule, clamped to a legal
        // Timer interval. Negative (the blip was already due) fires immediately.
        int RemainingDelay()
        {
            long remaining = NextDueMs - NowMs();
            if (remaining > int.MaxValue) return int.MaxValue;
            return remaining > 1 ? (int)remaining : 1;
        }

        // Plays the currently loaded sound exactly once. The one playback path
        // for scheduled ticks and previews: a synchronous Play() failure is
        // recorded and surfaces as the existing broken/ERR state instead of
        // vanishing while the app claims to be healthy. Returns whether a
        // playable sound was in hand.
        bool PlayNow()
        {
            if (Player == null) return false;
            try { Player.Play(); }
            catch (Exception ex)
            {
                // Only what the API can actually report: a synchronous playback
                // exception. Driver-level async failures are not detectable here
                // and are not claimed to be.
                LoadError = ex.Message;
                try { Player.Dispose(); } catch { }
                Player = null;
                return false;
            }
            return true;
        }

        // Deterministic test seam: invoked by BuildCache after the rebuild work.
        // A regression injects a fake advancing NowMs and this hook advances it,
        // proving the re-armed countdown consumes build time without sleeping a
        // real second anywhere. Production leaves both null/default.
        internal Action BuildDelaySim;

        // One immediate blip with the currently loaded sound. Preview is a
        // playback-only operation: it never flips Enabled, never arms or stops
        // the periodic timer, never draws a new interval, never touches the
        // pending countdown and never persists settings. If the asset is
        // unusable it attempts the same one-shot recovery Start() does; if that
        // fails the engine stays in its existing broken/ERR state and false is
        // returned -- preview never pretends to have played.
        // HEALTH EXCEPTION: a real playback failure IS surfaced. While ON it
        // also stops the periodic timer (a running engine must not keep
        // pretending to run on a dead asset) -- a health transition, never a
        // user ON/OFF command, so the remembered run preference is untouched.
        public bool Preview()
        {
            if (Player == null)
            {
                BuildCache();
                if (Player == null) return false;
            }
            if (!PlayNow())
            {
                if (Enabled)
                {
                    Enabled = false;
                    if (Timer != null) Timer.Stop();
                }
                NotifyStateChanged();
                return false;
            }
            PreviewCount++;
            NotifyStateChanged();
            return true;
        }

        void Tick(object sender, EventArgs e)
        {
            if (!Enabled || Player == null) return;
            // No play debounce: the supported intervals are >= 1 s
            // (Settings.MinMsFloor) and a WinForms.Timer never re-enters its
            // Tick handler, so every due tick plays. The old 300 ms
            // LastPlayMs guard protected no invariant a real interval could
            // violate -- and with the broken per-call clock it suppressed
            // every scheduled tick after the first (recurring playback died
            // in production while every fake-clock test stayed green).
            if (!PlayNow())
            {
                // Scheduled playback failed: the engine must not keep
                // claiming healthy ON with a dead asset. Stop periodic
                // scheduling, arm nothing, retain the error (ERR state),
                // and leave recovery to an explicit Start()/Preview().
                Enabled = false;
                if (Timer != null) Timer.Stop();
                NotifyStateChanged();
                return;
            }
            // Scheduled-play observation seam (tests\\engine contract): counted
            // only here, only after a successful scheduled PlayNow(). A
            // regression where Tick merely re-arms without playing must fail
            // the scheduled-count assertion instead of passing structurally.
            ScheduledPlayCount++;
            // One successful scheduled blip == one recorded count. Memory is
            // updated BEFORE subscribers repaint, so a BlipPlayed handler sees
            // the new total. A stats flush failure is absorbed inside the store
            // and can never throw into this audio path.
            Stats.RecordBlip();
            RaiseBlipPlayed();
            ArmTimer(NextDelay());
        }

        public void Start()
        {
            // A missing or corrupt sound asset is not "running": leaving Enabled
            // true here is exactly what made a broken WAV look identical to a
            // working one. Retry the load once -- the file may have been fixed
            // since startup -- and stay off if it is still unusable.
            if (Player == null)
            {
                BuildCache();
                if (Player == null) { Enabled = false; NotifyStateChanged(); return; }
            }
            // IDEMPOTENT ON: a Start on an already-healthy running engine is a
            // scheduling no-op. The ON rectangle in the settings window is
            // always an active hot zone, so clicking the already-selected ON
            // used to reach this method and replace the pending countdown with
            // a fresh NextDelay() — an "already active" toggle that silently
            // reset the user's wait. Recovery still runs whenever the engine
            // is broken (Player == null, handled above); only the healthy-ON
            // path returns early, and nothing changed means nothing notifies.
            // Interval changes keep re-arming through SetRange().
            if (Enabled) return;
            Enabled = true;
            // A genuinely new Start resets the PULSE phase: the first scheduled
            // blip of any fresh session is the 5-second short slot (the Windows
            // first-blip contract -- the selected interval governs the first
            // blip, there is no separate sub-second startup blip).
            PulseShortNext = true;
            // The configured interval governs the FIRST blip too. The old
            // hard-coded 500 ms meant a fresh Start on 30 s waited half a second
            // and then kept the old pending interval anyway.
            ArmTimer(NextDelay());
            Timer.Start();
            NotifyStateChanged();
        }
        public void Stop()
        {
            Enabled = false;
            if (Timer != null) Timer.Stop();
            // A stopped session resets the PULSE phase; the next Start begins
            // at the short slot again.
            PulseShortNext = true;
            // Bounded write contract: an explicit Stop is a natural flush point.
            // Best-effort only -- a failure keeps the dirty state for a later
            // retry and must not affect the ON/OFF transition below.
            if (Stats != null) Stats.FlushIfDirty();
            NotifyStateChanged();
        }
        // Change the interval identity. kind + minMs/maxMs carry mode and bounds
        // in ONE call (for Range: the preset ms; for Manual: resolved bounds;
        // for Pulse: the slot constants are engine-owned, the ms are ignored).
        //
        //   same effective config: no-op -- clicking the already-selected
        //     preset/mode again never restarts the countdown.
        //   changed config while OFF: fields update only; nothing starts.
        //   changed config while ON: fields update, the pulse phase resets when
        //     the mode transition requires it (into/out of Pulse), and a delay
        //     from the NEW config is armed immediately, discarding the pending
        //     wait -- the established Windows contract for interval changes.
        public void SetInterval(IntervalKind kind, int minMs, int maxMs)
        {
            bool modeChanged = kind != Kind;
            bool sameConfig = kind == Kind
                && (kind != IntervalKind.Range || (minMs == MinMs && maxMs == MaxMs))
                && (kind != IntervalKind.Manual || (minMs == ManualMinMs && maxMs == ManualMaxMs));
            if (sameConfig && !modeChanged) return;      // idempotent repeat
            if (kind == IntervalKind.Range) { MinMs = minMs; MaxMs = maxMs; }
            if (kind == IntervalKind.Manual) { ManualMinMs = minMs; ManualMaxMs = maxMs; }
            Kind = kind;
            // A mode transition always resets the pulse phase (fresh session
            // state); identical-config repeats never reach here.
            if (modeChanged && kind == IntervalKind.Pulse) PulseShortNext = true;
            if (Timer != null && Enabled)
            {
                // An interval change intentionally discards the old pending
                // delay and draws a fresh one from the NEW config. This is the
                // opposite contract of a volume reload, which must preserve it.
                Timer.Stop();
                ArmTimer(NextDelay());
                Timer.Start();
            }
        }

        // Backward-compatible helper for callers that only change the ordinary
        // Range preset values.
        public void SetRange(int minMs, int maxMs)
        {
            SetInterval(IntervalKind.Range, minMs, maxMs);
        }
        // Rebuild the cached WAV without changing on/off and without disturbing
        // the pending countdown. Reload used to end in Start() unconditionally
        // -- dragging the volume while OFF switched the engine back ON, and
        // while ON it re-drew a fresh interval, resetting the wait the user was
        // halfway through. Now: OFF stays OFF; ON rebuilds and re-arms with the
        // REMAINING wait, clamped to a legal timer interval. A failed rebuild
        // while running is not reported as a healthy ON with nothing playable:
        // it transitions to the existing truthful broken/ERR state (Stop) while
        // retaining enough that a later Start/Preview can recover.
        public void Reload()
        {
            if (!Enabled)
            {
                bool wasBroken = IsBroken;
                BuildCache();
                // A reload that changes health (broken -> playable) is
                // observable; report it. An OFF reload on an already-playable
                // asset changes nothing observable.
                if (wasBroken != IsBroken) NotifyStateChanged();
                return;                      // OFF stays OFF; no timer is started.
            }
            // Capture the ABSOLUTE due time BEFORE the rebuild, so the time the
            // rebuild itself takes is consumed from the existing countdown
            // instead of shifting the scheduled blip later. Computing the
            // remaining delay first would silently add build time to the wait.
            long due = NextDueMs;
            BuildCache();
            if (Player == null)
            {
                Stop();                      // broken while running: truthful ERR.
                return;                      // Stop() already notified.
            }
            // Still running. The timer never stopped, so assigning the preserved
            // remaining wait (ArmTimer sets Interval) restarts it unchanged --
            // a volume change must NOT draw a fresh NextDelay(). The re-armed
            // wait is measured from the original absolute due time, so a slow
            // rebuild does not extend the schedule.
            long remaining = due - NowMs();
            if (remaining > int.MaxValue) remaining = int.MaxValue;
            if (remaining < 1) remaining = 1;
            ArmTimer((int)remaining);
        }
        public bool IsOn { get { return Enabled; } }
        public bool IsBroken { get { return Player == null; } }
        public string StateText { get { return IsBroken ? "ERR" : (Enabled ? "ON" : "OFF"); } }
        // One line the UI can show verbatim: the asset that failed plus why.
        public string FailureText
        {
            get
            {
                if (Player != null) return null;
                return "Sound not loaded: " + Path.GetFileName(S.WavPath)
                    + (string.IsNullOrEmpty(LoadError) ? "" : " — " + LoadError);
            }
        }
        // NotifyIcon.Text rejects anything over 63 characters, so the tray names
        // the explicit run state (ON/OFF/ERR) and the window carries the detail.
        public string TrayCaption
        {
            get
            {
                string t = "problip — " + StateText;
                return t.Length > 63 ? t.Substring(0, 63) : t;
            }
        }

        // Called on the way out: drop the last temp WAV so a normal exit leaves
        // nothing behind in %TEMP%. Idempotent -- a second call is a no-op.
        public void Cleanup()
        {
            Stop();
            if (Timer != null)
            {
                Timer.Tick -= Tick;
                Timer.Dispose();
                Timer = null;
            }
            try { if (Player != null) Player.Dispose(); } catch { }
            Player = null;
            if (CachePath != null)
            {
                try { if (File.Exists(CachePath)) File.Delete(CachePath); } catch { }
                CachePath = null;
            }
        }
    }

    // Shared ON/OFF command seam for the two UI surfaces (settings window and
    // tray menu), so their persistence behavior cannot drift. ON/OFF is an
    // immediate operational command: the engine obeys FIRST, the session's
    // desired run intent (Settings.RunOnLaunch) updates regardless of
    // persistence, and a failed INI write is reported WITHOUT undoing the
    // user's action. This intentionally differs from volume/range transactions
    // (where an unsaved value is reverted): a Stop must never be rolled back to
    // Start just because the INI is read-only.
    static class RunState
    {
        // Startup projection of the remembered preference: RunOnLaunch=1 arms
        // the beeper, RunOnLaunch=0 leaves a resident but paused tray app.
        // Extracted so regressions can drive the exact startup branch Main()
        // uses. A broken asset with RunOnLaunch=1 lands in ERR via Start()
        // itself -- never fake ON, and the preference is never rewritten.
        public static void ApplyLaunch(Settings s, BlipEngine engine)
        {
            if (s.RunOnLaunch) engine.Start();
        }

        public static void RequestStart(Settings s, BlipEngine engine)
        {
            s.RunOnLaunch = true;
            engine.Start();
            Save(s, "1", "ON");
        }

        public static void RequestStop(Settings s, BlipEngine engine)
        {
            s.RunOnLaunch = false;
            engine.Stop();
            Save(s, "0", "OFF");
        }

        static void Save(Settings s, string val, string state)
        {
            try { s.Save("RunOnLaunch", val); }
            catch (System.IO.IOException)
            {
                // The action already applied for this session; only the startup
                // preference could not be persisted. Do not roll back the run
                // state -- report the partial persistence instead.
                RaisePersistenceError(s, state);
            }
        }

        public static System.Action<string> PersistenceErrorSink;
        static void RaisePersistenceError(Settings s, string state)
        {
            string msg = "PROBLIP is " + state + " for this session,\r\n"
                + "but the startup state could not be saved.\r\n" + s.IniPath;
            if (PersistenceErrorSink != null) { PersistenceErrorSink(msg); return; }
            System.Windows.Forms.MessageBox.Show(null, msg, "problip",
                System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Warning);
        }
    }

    class ProblipForm : Form
    {
        Settings S;
        BlipEngine Engine;
        NotifyIcon Tray;
        List<HotZone> Hot = new List<HotZone>();
        // One Font per point size and one centered StringFormat for the whole
        // form lifetime. Every paint used to build ~20 pixel fonts and one
        // StringFormat per button, all of it churn in a process that stays
        // resident for days.
        Dictionary<int, Font> Fonts = new Dictionary<int, Font>();
        StringFormat Centered = new StringFormat();
        Rectangle VolTrack;
        bool VolDragging = false;
        // The volume committed when the drag started. If the release cannot
        // persist the new value, this is what the slider, the session and the
        // scaled cache go back to.
        double DragStartVolume;
        // Unit seam: tests point this at a disposable key so ToggleAutostart never
        // touches a developer's real Run entry, and can capture failure notices.
        string AutoStartKeyPath = AutoStart.RunKeyPath;
        // Unit seam: when set, persistence-failure notices land here instead of a
        // modal MessageBox, so regressions can observe the revert path. Production
        // leaves it null and the notice is the MessageBox.
        System.Action<string> SettingsErrorSink;
        // Opens the single live statistics view. Wired by Program so the BLIPS
        // line and the tray Statistics item share one instance, like ShowForm
        // owns the one settings window.
        public Action OpenStatistics;
        // Opens the single reusable manual-interval editor. Wired by Program to
        // the one ManualIntervalForm instance (same ownership pattern).
        public Action OpenManual;
        // Opens the single reusable theme picker. Wired by Program so the THEME
        // line and the tray Themes item share one window.
        public Action OpenThemes;
        // Opens the single reusable theme picker from the tray-visible setting.
        internal Rectangle BlipsRect;
        // Mode-row hit zones (MANUAL / PULSE).
        internal Rectangle ManualRect, PulseRect;
        // Utility-row hit zones (THEME / GLOW).
        internal Rectangle ThemeRect, GlowRect;
        // ── Blip Glow state ──
        // The one glow animation timer, owned by this form. It exists with the
        // form but runs ONLY during an active glow; this UI animation timer is
        // not the scheduler and never touches BlipEngine's timer or state.
        Timer GlowTimer;
        // Monotonic clock for glow animation progress only. Not readonly: a
        // regression swaps in a fresh Stopwatch to hold elapsed time near zero
        // (the real 260 ms animation window must not elapse inside a test).
        internal Stopwatch GlowClock = Stopwatch.StartNew();
        long GlowStartMs = -1;   // -1 = no active glow
        internal int GlowTimerStartCount;   // test seam: glow starts observed
        internal int GlowTimerStopCount;    // test seam: glow stops observed

        // Shared Start/Stop command seam: both UI surfaces (tray menu, settings
        // window) go through RunState so persistence behavior cannot drift. The
        // engine obeys FIRST, the session's desired run intent updates
        // regardless of persistence, and a failed INI write is reported WITHOUT
        // undoing the user's action -- an OFF must never be rolled back to ON
        // just because the INI is read-only (unlike volume/range transactions).
        public void RequestStart()
        {
            RunState.RequestStart(S, Engine);
            Refresh();
        }

        public void RequestStop()
        {
            RunState.RequestStop(S, Engine);
            Refresh();
        }

        // Runtime state changed while nobody was clicking: refresh the tray and
        // an open settings window so a mid-wait playback failure is visible
        // without any user action.
        void OnEngineStateChanged(object sender, EventArgs e)
        {
            SyncTray();
            Refresh();
        }

        // A scheduled successful blip updates the visible BLIPS total live, with
        // no polling: the engine pushes the event and this window repaints.
        void OnBlipPlayed(object sender, EventArgs e)
        {
            if (IsDisposed) return;
            // BLIP GLOW: the same successful scheduled-blip signal drives the
            // optional accent pulse. Hidden window => no animation, no timer, no
            // queued replay: the glow simply never starts (no stale glow when
            // the form is shown later). A new event while active restarts from
            // the rise origin; alpha never stacks beyond GlowModel.MaxAlpha.
            if (Visible && S.BlipGlow) StartGlow();
            Invalidate();
        }

        // Starts/restarts the glow from the rise origin. The timer runs only
        // while a glow is active and is stopped as soon as alpha reaches zero.
        void StartGlow()
        {
            GlowStartMs = GlowClock.ElapsedMilliseconds;
            if (GlowTimer == null)
            {
                GlowTimer = new Timer();
                GlowTimer.Interval = 16;
                GlowTimer.Tick += delegate(object o, EventArgs ea) { OnGlowTick(); };
            }
            if (!GlowTimer.Enabled)
            {
                GlowTimer.Start();
                GlowTimerStartCount++;
            }
            Invalidate();
        }

        void OnGlowTick()
        {
            if (GlowStartMs < 0) { StopGlow(); return; }
            int elapsed = (int)(GlowClock.ElapsedMilliseconds - GlowStartMs);
            if (elapsed >= GlowModel.TotalMs)
            {
                StopGlow();
                return;
            }
            Invalidate();
        }

        // Stops the animation and restores the normal background. Preference off
        // mid-animation also routes here: the glow halts immediately, audio and
        // scheduling untouched.
        void StopGlow()
        {
            bool wasRunning = GlowTimer != null && GlowTimer.Enabled;
            if (wasRunning) { GlowTimer.Stop(); GlowTimerStopCount++; }
            GlowStartMs = -1;
            if (IsDisposed) return;
            if (wasRunning || !S.BlipGlow) Invalidate();
        }

        // Current glow alpha for painting: pure math from GlowModel, 0 when no
        // glow is active or the preference is off.
        internal double CurrentGlowAlpha()
        {
            if (GlowStartMs < 0 || !S.BlipGlow) return 0.0;
            return GlowModel.Alpha((int)(GlowClock.ElapsedMilliseconds - GlowStartMs));
        }

        internal class HotZone
        {
            public Rectangle R;
            public Action A;
        }

        public ProblipForm(Settings s, BlipEngine engine, NotifyIcon tray)
        {
            S = s; Engine = engine; Tray = tray;
            Centered.Alignment = StringAlignment.Center;
            Centered.LineAlignment = StringAlignment.Center;
            Text = "problip";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            // The window is sized by the MEASURED bottom row (TEST included),
            // never by a guessed constant: 280 px stays when the row genuinely
            // fits, a few more when it does not. Measured on a screen-compatible
            // Graphics with the very fonts OnPaint uses.
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero))
            {
                int need, modeNeed;
                LayoutBottomRow(g, out need);
                LayoutModeRow(g, out modeNeed);
                LayoutUtilityRow(g);
                // Height grew by one compact BLIPS row (150 -> 168), then the
                // mode row (168 -> 190), then the THEME/GLOW utility row
                // (190 -> 216) rather than squeezing the existing controls; the
                // width still comes from the measured rows.
                ClientSize = new Size(Math.Max(Math.Max(280, need), modeNeed), 216);
            }
            BackColor = Palette.BG;
            DoubleBuffered = true;
            TopMost = true;
            // Apply the persisted theme to THIS form at construction (BackColor
            // and child state; the paint reads Palette.* directly).
            ApplyTheme();
            // Runtime truth without a click: any engine state transition repaints
            // this window and the tray. The form's lifetime bounds the
            // subscription; ShowForm keeps exactly one live instance.
            engine.StateChanged += OnEngineStateChanged;
            // Live BLIPS total: repaint on every successful scheduled blip.
            engine.BlipPlayed += OnBlipPlayed;
            // taskbar / alt-tab icon = the same pixel avatar mark
            try { Icon = AppIcon.For(s.IcoPath, SystemInformation.IconSize.Width); }
            catch { }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                Engine.StateChanged -= OnEngineStateChanged;
                Engine.BlipPlayed -= OnBlipPlayed;
                if (GlowTimer != null)
                {
                    GlowTimer.Tick -= delegate(object o, EventArgs ea) { OnGlowTick(); };
                    GlowTimer.Dispose();
                    GlowTimer = null;
                }
                foreach (Font f in Fonts.Values) f.Dispose();
                Fonts.Clear();
                Centered.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == Native.WM_NCHITTEST)
            {
                // LParam packs two SIGNED 16-bit screen coords. A checked (int)
                // cast of the IntPtr overflows for a point on a monitor above the
                // primary, killing the drag strip there.
                int raw = unchecked((int)m.LParam.ToInt64());
                int x = raw & 0xFFFF;
                int y = (raw >> 16) & 0xFFFF;
                if (x > 0x7FFF) x -= 0x10000;
                if (y > 0x7FFF) y -= 0x10000;
                Point p = PointToClient(new Point(x, y));
                if (p.Y < 20 && p.X < Width - 20)
                {
                    m.Result = (IntPtr)Native.HTCAPTION;
                }
            }
        }

        // Font.FromHfont does NOT take ownership of the handle: every call leaks
        // one GDI object until the process dies, and OnPaint builds ~20 of them
        // per repaint. Clone into a managed Font, then delete the HFONT.
        // Internal so the statistics form paints with the identical pixel font.
        internal static Font MakePixelFont(string name, int pt)
        {
            IntPtr hf = Native.CreateFont(-(int)(pt * 96 / 72), 0, 0, 0, 400,
                0, 0, 0, 1, 0, 0, Native.NONANTIALIASED_QUALITY, 0, name);
            try { using (Font wrapped = Font.FromHfont(hf)) return (Font)wrapped.Clone(); }
            finally { if (hf != IntPtr.Zero) Native.DeleteObject(hf); }
        }

        // Cached for the form's lifetime: the caller never owns the Font and
        // must not dispose it. Released in Dispose.
        Font F(int pt)
        {
            Font f;
            if (!Fonts.TryGetValue(pt, out f))
            {
                f = MakePixelFont("Verdana", pt);
                Fonts[pt] = f;
            }
            return f;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            g.SmoothingMode = SmoothingMode.None;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.CompositingQuality = CompositingQuality.HighSpeed;
            g.Clear(Palette.BG);
            Hot.Clear();

            // Blip Glow underlay: a soft CURRENT-ACCENT tint behind everything,
            // blended into the background. Never white; peak alpha 25%.
            double glow = CurrentGlowAlpha();
            if (glow > 0.0)
            {
                Color gc = Palette.LINK;
                using (var gb = new SolidBrush(Color.FromArgb((int)Math.Round(glow * 255.0), gc)))
                    g.FillRectangle(gb, 0, 0, ClientSize.Width, ClientSize.Height);
            }

            // title bar
            using (var b = new SolidBrush(Palette.SURFACE)) g.FillRectangle(b, 0, 0, Width, 20);
            DrawText(g, "problip", 8, 4, Palette.TEXT, 12, true);
            var xr = new Rectangle(Width - 20, 0, 20, 20);
            Hot.Add(MakeHot(xr, delegate() { Hide(); }));
            DrawText(g, "X", Width - 16, 4, Palette.TEXT2, 12, true);

            // status — only the truth, top-right. A broken sound asset is its own
            // state: reporting ON while nothing can play is the defect this
            // replaces.
            string st = Engine.IsBroken ? "ERR" : (Engine.IsOn ? "ON" : "OFF");
            Color stc = Engine.IsBroken ? Palette.DANGERTXT : (Engine.IsOn ? Palette.SUCCESS : Palette.MUTED);
            int sw = (int)g.MeasureString(st, F(12)).Width;
            DrawText(g, st, Width - 24 - sw, 4, stc, 12, true);

            // ── BLIPS total: one compact line under the title/status row ──
            // Dim text, no panel, no progress bar. Clicking it opens the shared
            // statistics view. Hiding it is pure visibility -- recording never
            // stops. Grouped with the user's culture; at enormous values the
            // hit zone simply grows with the measured text and stays clipped by
            // the client rect.
            BlipsRect = Rectangle.Empty;
            if (S.ShowBlipCounter)
            {
                long total = Engine.Stats.Snapshot().Total;
                string blips = "BLIPS " + total.ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
                DrawText(g, blips, 8, 22, Palette.TEXT2, 11);
                int bw = TextW(g, blips, 11);
                BlipsRect = new Rectangle(6, 20, bw + 4, 16);
                Hot.Add(MakeHot(BlipsRect, delegate() { if (OpenStatistics != null) OpenStatistics(); }));
            }

            // ── volume slider 0..100 ──
            int yv = 42;
            DrawText(g, "vol", 8, yv + 2, Palette.TEXT2, 11);
            VolTrack = new Rectangle(36, yv, 168, 12);
            DrawBevel(g, VolTrack, false);
            int pct = (int)Math.Round(S.Volume * 100);
            using (var bg = new SolidBrush(Palette.SURFACE)) g.FillRectangle(bg, VolTrack.X + 1, VolTrack.Y + 1, VolTrack.Width - 2, VolTrack.Height - 2);
            using (var fill = new SolidBrush(Palette.LINK))
                g.FillRectangle(fill, VolTrack.X + 1, VolTrack.Y + 1, (int)((VolTrack.Width - 2) * S.Volume), VolTrack.Height - 2);
            int thx = VolTrack.X + (int)((VolTrack.Width - 10) * S.Volume);
            var thr = new Rectangle(thx, yv - 3, 10, 18);
            Hot.Add(MakeHot(thr, delegate() { StartVolumeDrag(); }));
            DrawBevel(g, thr, true);
            using (var tb = new SolidBrush(Palette.ALT)) g.FillRectangle(tb, thr.X + 1, thr.Y + 1, thr.Width - 2, thr.Height - 2);
            DrawText(g, pct + "%", 210, yv + 1, Palette.TEXT, 11, true);

            // ── interval presets ──
            int yi = PresetRowY;
            DrawText(g, "sec", 8, yi + 4, Palette.TEXT2, 11);
            int xi = 32;
            int[] mins = new int[] { 4, 5, 10, 15, 20, 30 };
            int[] maxs = new int[] { 7, 5, 10, 15, 20, 30 };
            for (int i = 0; i < mins.Length; i++)
            {
                int mn = mins[i] * 1000, mx = maxs[i] * 1000;
                bool sel = S.Kind == IntervalKind.Range && S.MinMs == mn && S.MaxMs == mx;
                string lbl = mn == mx ? (mn / 1000) + "s" : (mn / 1000) + "-" + (mx / 1000);
                int w = TextW(g, lbl, 10) + 10;
                var r = new Rectangle(xi, yi, w, 22);
                int cmn = mn, cmx = mx;
                Hot.Add(MakeHot(r, delegate() { ApplyRange(cmn, cmx); }));
                DrawButton(g, r, lbl, sel, 10);
                xi += w + 3;
            }

            // ── mode row: MANUAL / PULSE ──
            // One compact second row under the ordinary presets. Range selects a
            // preset only; Manual and Pulse select their own buttons, leaving
            // every ordinary preset unselected.
            LayoutModeRow(g, out modeNeedIgnored);
            bool manualSel = S.Kind == IntervalKind.Manual;
            bool pulseSel = S.Kind == IntervalKind.Pulse;
            Hot.Add(MakeHot(ManualRect, delegate() { OpenManualEditor(); }));
            string manualLabel = manualSel ? "MANUAL " + S.ManualFromSec + "-" + S.ManualToSec : "MANUAL";
            DrawButton(g, ManualRect, manualLabel, manualSel, 9);
            Hot.Add(MakeHot(PulseRect, delegate() { ApplyPulse(); }));
            DrawButton(g, PulseRect, "PULSE", pulseSel, 9);

            // ── utility row: THEME / GLOW ──
            // One measured line between the mode row and the bottom row. The
            // theme name truncates within its allotted rectangle (real TextW
            // measurement), never drawing outside the client.
            LayoutUtilityRow(g);
            Hot.Add(MakeHot(ThemeRect, delegate() { if (OpenThemes != null) OpenThemes(); }));
            DrawText(g, "THEME", ThemeRect.X, ThemeRect.Y + 4, Palette.TEXT2, 10);
            string themeName = ThemeModel.ById(S.ThemeId).Name;
            DrawText(g, TruncateThemeName(g, themeName, ThemeNameMaxWidth(g)),
                     ThemeRect.X + ThemeLabelW + 6, ThemeRect.Y + 4, Palette.TEXT, 10, true);
            bool glowOn = S.BlipGlow;
            Hot.Add(MakeHot(GlowRect, delegate() { ToggleGlow(); }));
            DrawButton(g, GlowRect, glowOn ? "[X] GLOW" : "[ ] GLOW", glowOn, 9);

            // ── bottom row: autostart + ON/OFF + TEST ──
            // One calculation shared by OnPaint and the ctor's ClientSize:
            // TEST is measured (TextW) and pinned to the RIGHT edge, then
            // OFF and ON toward the left, autostart anchored left. The row
            // can no longer clip a label ("TEST" -> "TE" happened because
            // the rect was a hard-coded guess).
            bool ao = AutoStartEnabled();
            int needW;
            LayoutBottomRow(g, out needW);
            var ar = AutoRect;
            Hot.Add(MakeHot(ar, delegate() { ToggleAutostart(); }));
            DrawButton(g, ar, ao ? "[X] autostart" : "[ ] autostart", ao, 10);

            // ON/OFF reflect the ACTUAL runtime state (ERR = neither selected;
            // the status text above stays the authoritative health indicator).
            // Both route through RequestStart/RequestStop so the remembered
            // run preference is updated exactly like the tray menu's Start/Stop.
            bool runOn = Engine.IsOn && !Engine.IsBroken;
            var sr = StartRect;
            Hot.Add(MakeHot(sr, delegate() { RequestStart(); }));
            DrawButton(g, sr, "ON", runOn);
            var pr = StopRect;
            Hot.Add(MakeHot(pr, delegate() { RequestStop(); }));
            DrawButton(g, pr, "OFF", !Engine.IsBroken && !Engine.IsOn);
            // Compact explicit preview affordance: same Engine.Preview() API the
            // tray Test blip and the volume commit use -- no second sound path.
            var tr = TestRect;
            Hot.Add(MakeHot(tr, delegate() { Engine.Preview(); SyncTray(); Refresh(); }));
            DrawButton(g, tr, "TEST", false, 9);

            // The reason, in the window, when there is one. Pressing ON with a
            // broken asset retries the load and this line either goes away or
            // says why it did not.
            string failure = Engine.FailureText;
            if (failure != null)
                DrawText(g, Truncate(g, failure, Width - 16, 10), 8, FailureTextY, Palette.DANGERTXT, 10);
        }

        // Clip a message to the window instead of letting it run off the edge:
        // the point of showing the failure is that the user can read it.
        string Truncate(Graphics g, string s, int maxWidth, int pt)
        {
            if (TextW(g, s, pt) <= maxWidth) return s;
            while (s.Length > 4 && TextW(g, s.Substring(0, s.Length - 4) + "...", pt) > maxWidth)
                s = s.Substring(0, s.Length - 1);
            return s.Substring(0, Math.Max(1, s.Length - 4)) + "...";
        }

        static HotZone MakeHot(Rectangle r, Action a)
        {
            HotZone h = new HotZone();
            h.R = r;
            h.A = a;
            return h;
        }

        void DrawText(Graphics g, string s, int x, int y, Color c, int pt, bool bold = false)
        {
            Font f = F(pt);
            using (var br = new SolidBrush(c))
                g.DrawString(s, f, br, (float)x, (float)y);
        }

        void DrawBevel(Graphics g, Rectangle r, bool raised)
        {
            Color hi = raised ? Palette.BEVEL : Palette.BDARK;
            Color lo = raised ? Palette.BDARK : Palette.BEVEL;
            using (var p1 = new Pen(hi)) g.DrawRectangle(p1, r.X, r.Y, r.Width - 1, r.Height - 1);
            using (var p2 = new Pen(lo)) g.DrawRectangle(p2, r.X + 1, r.Y + 1, r.Width - 3, r.Height - 3);
        }

        void DrawButton(Graphics g, Rectangle r, string label, bool selected, int pt = 12)
        {
            using (var bg = new SolidBrush(selected ? Palette.COMPARE : Palette.RAISED))
                g.FillRectangle(bg, r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4);
            DrawBevel(g, r, !selected);
            Font f = F(pt);
            using (var br = new SolidBrush(selected ? Palette.LINK : Palette.TEXT))
                g.DrawString(label, f, br, new RectangleF(r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4), Centered);
        }

        // measure text width in px at given pt, for sizing buttons to their label
        int TextW(Graphics g, string s, int pt)
        {
            return (int)Math.Ceiling(g.MeasureString(s, F(pt)).Width);
        }

        // Bottom-row hit zones, shared by OnPaint and the layout regression.
        internal Rectangle AutoRect, StartRect, StopRect, TestRect;
        // Row geometry, shared by OnPaint, the layout methods and the layout
        // regression: preset row, mode row, bottom row and the failure line
        // under the bottom row.
        internal const int PresetRowY = 68;
        internal const int ModeRowY = 94;
        internal const int UtilityRowY = 122;
        internal const int BottomRowY = 148;
        internal const int FailureTextY = BottomRowY + 26;   // 174
        // The THEME row's fixed "THEME" label allowance plus the gap before the
        // theme name; the name itself truncates inside the remaining width.
        internal const int ThemeLabelW = 40;
        // The theme name's allotted rectangle (measured each paint, cached for
        // the layout regression).
        internal Rectangle ThemeNameRect;

        // The width the theme name may occupy: from after the THEME label to
        // just left of the GLOW button.
        int ThemeNameMaxWidth(Graphics g)
        {
            return GlowRect.X - 8 - (ThemeRect.X + ThemeLabelW + 6);
        }

        // Truncate the theme name with real text measurement so a long name
        // never paints outside its allotted rectangle.
        string TruncateThemeName(Graphics g, string name, int maxWidth)
        {
            if (TextW(g, name, 10) <= maxWidth) return name;
            string t = name;
            while (t.Length > 1 && TextW(g, t + "…", 10) > maxWidth)
                t = t.Substring(0, t.Length - 1);
            return t + "…";
        }

        // The utility row as one measurement: THEME label + name on the left,
        // the GLOW toggle sized from its measured label on the right. Shared by
        // OnPaint and the ctor's ClientSize height decision.
        internal void LayoutUtilityRow(Graphics g)
        {
            const int yu = UtilityRowY, h = 22, margin = 8;
            int glowW = Math.Max(TextW(g, "[X] GLOW", 9), TextW(g, "[ ] GLOW", 9)) + 14;
            GlowRect = new Rectangle(Width - margin - glowW, yu, glowW, h);
            ThemeRect = new Rectangle(margin, yu, 0, h);
            ThemeNameRect = new Rectangle(ThemeRect.X + ThemeLabelW + 6, yu,
                Math.Max(10, ThemeNameMaxWidth(g)), h);
        }
        // Mode-row width need, written by OnPaint through LayoutModeRow (the
        // ctor also consults it before the window exists; Out parameter cannot
        // be stored, so the field keeps the last measurement).
        int modeNeedIgnored;

        // The whole mode row as one measurement, same contract as
        // LayoutBottomRow: MANUAL is sized from its WIDEST label (selected
        // "MANUAL f-t" included) so switching selection never resizes or clips
        // the row, PULSE from its own label; neededWidth is the minimum client
        // width that fits both.
        internal void LayoutModeRow(Graphics g, out int neededWidth)
        {
            const int ym = ModeRowY, h = 22, gap = 4, margin = 8;
            int manualW = Math.Max(TextW(g, "MANUAL", 9), TextW(g, "MANUAL 3600-3600", 9)) + 14;
            int pulseW = TextW(g, "PULSE", 9) + 14;
            ManualRect = new Rectangle(margin, ym, manualW, h);
            PulseRect = new Rectangle(ManualRect.Right + gap, ym, pulseW, h);
            neededWidth = margin + manualW + gap + pulseW + margin;
        }

        // The whole bottom row as one measurement, never a guessed constant:
        // TEST is sized from its own label and pinned to the right margin,
        // OFF and ON follow toward the left, autostart stays anchored at the
        // left margin. neededWidth reports the minimum client width that fits
        // the row, so the ctor sizes the window to the truth instead of
        // clipping a label to its prefix.
        internal void LayoutBottomRow(Graphics g, out int neededWidth)
        {
            const int yb = BottomRowY, h = 22, gap = 4, margin = 8;
            int testW = TextW(g, "TEST", 9) + 14;
            int pairW = Math.Max(TextW(g, "OFF", 12), TextW(g, "ON", 12)) + 14;
            int autoW = Math.Max(TextW(g, "[X] autostart", 10), TextW(g, "[ ] autostart", 10)) + 14;
            TestRect = new Rectangle(Width - margin - testW, yb, testW, h);
            StopRect = new Rectangle(TestRect.X - gap - pairW, yb, pairW, h);
            StartRect = new Rectangle(StopRect.X - gap - pairW, yb, pairW, h);
            AutoRect = new Rectangle(margin, yb, autoW, h);
            neededWidth = margin + autoW + gap + pairW + gap + pairW + gap + testW + margin;
        }

        void StartVolumeDrag()
        {
            DragStartVolume = S.Volume;
            VolDragging = true;
        }

        void SetVolumeFromX(int x)
        {
            double v = (double)(x - VolTrack.X) / (VolTrack.Width - 10);
            if (v < 0) v = 0; else if (v > 1) v = 1;
            S.Volume = v;
            // Dragging fires a mouse move per pixel; Invalidate lets the moves
            // coalesce into one repaint instead of forcing a synchronous paint
            // for each event.
            Invalidate();
        }

        // Commits the dragged volume. A failed save must NOT look saved: the
        // committed value is restored everywhere (slider, session, scaled cache)
        // and the failure is reported, rather than the UI silently showing a value
        // the INI will overwrite on restart. A rejected value is never previewed.
        // On success: rebuild once at the new volume, then preview exactly once.
        void EndVolumeDrag()
        {
            if (!VolDragging) return;
            VolDragging = false;
            double committed = DragStartVolume;
            try
            {
                S.Save("Volume", S.Volume.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture));
            }
            catch (System.IO.IOException)
            {
                S.Volume = committed;
                Engine.Reload();
                ShowSettingsSaveError("volume");
                SyncTray();
                Refresh();
                return;
            }
            Engine.Reload();
            Engine.Preview();
            SyncTray();
            Refresh();
        }

        // Modal or testable notice that a user-triggered persistence change could
        // not be committed. Used only for explicit user setting changes, never for
        // the best-effort default write on a fresh/read-only start.
        void ShowSettingsSaveError(string setting)
        {
            NotifySettingsError(setting,
                "Could not save the " + setting + " setting.\r\nThe previous value stays in effect.\r\n" + S.IniPath);
        }

        void NotifySettingsError(string key, string message)
        {
            if (SettingsErrorSink != null) { SettingsErrorSink(key); return; }
            MessageBox.Show(this, message, "problip", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        // The tray caption is the only thing that reports the engine's health
        // while the window is hidden, so any state change refreshes it.
        void SyncTray()
        {
            try { if (Tray != null) Tray.Text = Engine.TrayCaption; } catch { }
        }

        // ── Theme / Glow commands ──

        // Project the CURRENT palette onto this form's non-painted state (the
        // window background). Called by the ctor and on every theme switch; the
        // painted content follows automatically because OnPaint reads Palette.*.
        internal void ApplyTheme()
        {
            BackColor = Palette.BG;
            Invalidate();
        }

        // Glow preference as one explicit transaction: persist first, apply
        // second. A failed save keeps the previous preference and reports once.
        // Turning glow OFF immediately stops any active animation; turning it ON
        // never creates a glow by itself.
        internal void ToggleGlow()
        {
            bool previous = S.BlipGlow;
            bool next = !previous;
            try
            {
                S.Save("BlipGlow", next ? "1" : "0");
            }
            catch (System.IO.IOException)
            {
                ShowSettingsSaveError("glow");
                Refresh();
                return;
            }
            S.BlipGlow = next;
            if (!next) StopGlow();      // OFF: halt the running animation now
            Refresh();
        }

        // Commits a Range preset as one interval transaction: persist kind +
        // bounds first (one SaveIntervalState call), apply the engine change
        // only after persistence succeeds. On any write failure the previous
        // Settings state, the engine configuration and the UI selection stay on
        // the previously committed interval, already-written keys are restored
        // best-effort, and the failure is reported once.
        void ApplyRange(int mn, int mx)
        {
            var next = new[] {
                KV("IntervalKind", "range"),
                KV("MinMs", mn.ToString()),
                KV("MaxMs", mx.ToString())
            };
            var previous = new[] {
                KV("IntervalKind", IntervalModel.KindKey(S.Kind)),
                KV("MinMs", S.MinMs.ToString()),
                KV("MaxMs", S.MaxMs.ToString())
            };
            if (!S.SaveIntervalState(next, previous))
            {
                ShowSettingsSaveError("interval");
                Refresh();
                return;
            }
            S.Kind = IntervalKind.Range;
            S.MinMs = mn; S.MaxMs = mx;
            // Range ownership lives in the engine: SetInterval re-arms a running
            // timer instead of leaving the old wait pending.
            Engine.SetInterval(IntervalKind.Range, mn, mx);
            Refresh();
        }

        // Commits a MANUAL interval (already-sanitized seconds) as one
        // transaction. Returns whether it landed, so the editor knows whether to
        // close or keep asking. On failure everything stays on the previous
        // interval configuration and one concise error is reported.
        internal bool ApplyManual(int fromSec, int toSec)
        {
            int[] n = IntervalModel.SanitizeManual(fromSec, toSec);
            var next = new[] {
                KV("ManualFromSec", n[0].ToString()),
                KV("ManualToSec", n[1].ToString()),
                KV("IntervalKind", "manual")
            };
            var previous = new[] {
                KV("ManualFromSec", S.ManualFromSec.ToString()),
                KV("ManualToSec", S.ManualToSec.ToString()),
                KV("IntervalKind", IntervalModel.KindKey(S.Kind))
            };
            if (!S.SaveIntervalState(next, previous))
            {
                ShowSettingsSaveError("interval");
                Refresh();
                return false;
            }
            S.ManualFromSec = n[0];
            S.ManualToSec = n[1];
            S.Kind = IntervalKind.Manual;
            Engine.SetInterval(IntervalKind.Manual, n[0] * 1000, n[1] * 1000);
            Refresh();
            return true;
        }

        // Selects PULSE as one transaction. Pulse has no extra persisted keys --
        // only the kind changes, the ordinary Range bounds stay untouched so
        // switching back never re-derives anything. On failure the previous
        // mode and its schedule stay active.
        internal void ApplyPulse()
        {
            var next = new[] { KV("IntervalKind", "pulse") };
            var previous = new[] { KV("IntervalKind", IntervalModel.KindKey(S.Kind)) };
            if (!S.SaveIntervalState(next, previous))
            {
                ShowSettingsSaveError("interval");
                Refresh();
                return;
            }
            S.Kind = IntervalKind.Pulse;
            Engine.SetInterval(IntervalKind.Pulse, S.MinMs, S.MaxMs);
            Refresh();
        }

        static System.Collections.Generic.KeyValuePair<string, string> KV(string k, string v)
        {
            return new System.Collections.Generic.KeyValuePair<string, string>(k, v);
        }

        // Opens the single reusable manual-interval editor. Opening or
        // cancelling it is never a scheduling event: no persistence, no re-arm,
        // no phase change -- only APPLY through ApplyManual can change timing.
        internal void OpenManualEditor()
        {
            if (OpenManual != null) { OpenManual(); return; }
        }

        // True only when the Run entry exists AND points at this executable.
        // A stale "Problip" value from a moved/deleted copy used to present an
        // old path as a healthy enabled state.
        bool AutoStartEnabled()
        {
            return AutoStart.IsEnabled(AutoStartKeyPath, Application.ExecutablePath);
        }

        // problip.ini is the authoritative setting; the Run key is its projection,
        // reapplied from the INI on every launch (see Main). Registry and INI are
        // one user operation: if either half fails the other is restored AND the
        // in-memory S.AutoStart goes back to its previous value, so the durable and
        // in-memory states agree after the rollback instead of leaving the session
        // believing a setting the INI never accepted.
        void ToggleAutostart()
        {
            bool previousAutoStart = S.AutoStart;
            bool enable = !AutoStartEnabled();
            bool registryDone = false;
            bool rolledBack = true;
            try
            {
                // Set/Clear only report success after the Run entry is verified
                // to match this executable (or, for Clear, to be gone). A
                // mutation that did not land as requested is not "done".
                registryDone = enable
                    ? AutoStart.Set(AutoStartKeyPath, Application.ExecutablePath)
                    : AutoStart.Clear(AutoStartKeyPath);
                if (!registryDone)
                    throw new System.IO.IOException("the Run-key change was not verified");
                S.AutoStart = enable;
                S.Save("AutoStart", enable ? "1" : "0");
            }
            catch
            {
                if (registryDone)
                {
                    // INI write failed after the Run key changed: roll the
                    // registry back to the previous consistent state. A rollback
                    // that itself fails is reported, never silently accepted.
                    rolledBack = false;
                    try
                    {
                        bool back = enable
                            ? AutoStart.Clear(AutoStartKeyPath)
                            : AutoStart.Set(AutoStartKeyPath, Application.ExecutablePath);
                        rolledBack = back;
                    }
                    catch { }
                }
                S.AutoStart = previousAutoStart;
                if (!rolledBack)
                    NotifySettingsError("autostart",
                        "The autostart setting could not be committed\r\nand could not be rolled back cleanly.\r\n" + S.IniPath);
                else
                    ShowSettingsSaveError("autostart");
                Refresh();
                return;
            }
            Refresh();
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left)
            {
                if (VolTrack.Contains(e.Location))
                {
                    StartVolumeDrag();
                    SetVolumeFromX(e.X);
                    return;
                }
                foreach (HotZone h in Hot)
                {
                    if (h.R.Contains(e.Location)) { h.A(); return; }
                }
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (VolDragging && e.Button == MouseButtons.Left)
            {
                SetVolumeFromX(e.X);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (VolDragging)
            {
                EndVolumeDrag();
            }
        }

    }

    // Compact custom-painted MANUAL interval editor. One reusable instance is
    // owned by Program (same ownership pattern as the statistics view) and
    // opened from the settings window's MANUAL button. APPLY routes through
    // ProblipForm.ApplyManual, which persists and re-arms; the editor only
    // closes when that succeeded. CANCEL/X change nothing at all.
    class ManualIntervalForm : Form
    {
        Settings S;
        Func<int, int, bool> ApplyManual;
        List<ProblipForm.HotZone> Hot = new List<ProblipForm.HotZone>();
        Font PixelFont;
        StringFormat Centered = new StringFormat();
        TextBox FromBox, ToBox;
        // Painted geometry, exposed for the layout regression: the input frames
        // the parent draws around the borderless TextBoxes and the two buttons.
        internal Rectangle FromFrame, ToFrame, ApplyRect, CancelRect;
        int FocusIndex;      // 0 = FROM, 1 = TO, 2 = APPLY, 3 = CANCEL (Tab order)

        public ManualIntervalForm(Settings s, Func<int, int, bool> applyManual)
        {
            S = s; ApplyManual = applyManual;
            Centered.Alignment = StringAlignment.Center;
            Centered.LineAlignment = StringAlignment.Center;
            Text = "problip manual interval";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(220, 132);
            BackColor = Palette.BG;
            DoubleBuffered = true;
            TopMost = true;
            PixelFont = ProblipForm.MakePixelFont("Verdana", 11);
            try { Icon = AppIcon.For(s.IcoPath, SystemInformation.IconSize.Width); }
            catch { }

            // Borderless numeric inputs: the parent paints the bevel/input frame
            // around them (no stock borders), digits only, MaxLength 4. The
            // four-state keyboard contract (FROM -> TO -> APPLY -> CANCEL) is
            // owned ENTIRELY by ProcessDialogKey below: normal WinForms dialog-key
            // handling would otherwise process Tab as focus navigation before
            // this custom model could own it.
            FromBox = MakeBox(0);
            ToBox = MakeBox(1);
            Controls.Add(FromBox);
            Controls.Add(ToBox);
        }

        TextBox MakeBox(int tabIndex)
        {
            var box = new TextBox();
            box.BorderStyle = BorderStyle.None;
            box.BackColor = Palette.SURFACE;
            box.ForeColor = Palette.TEXT;
            box.Font = PixelFont;
            box.MaxLength = 4;
            box.TextAlign = HorizontalAlignment.Center;
            box.TabStop = true;
            box.TabIndex = tabIndex;
            box.KeyPress += delegate(object o, KeyPressEventArgs e)
            {
                if (!char.IsDigit(e.KeyChar) && !char.IsControl(e.KeyChar)) e.Handled = true;
            };
            // A mouse click into a box moves the LOGICAL focus back to it; the
            // painted APPLY/CANCEL selection follows the same state.
            box.GotFocus += delegate(object o, EventArgs e) { if (FocusIndex != tabIndex) { FocusIndex = tabIndex; Invalidate(); } };
            return box;
        }

        // The one keyboard seam. WinForms routes Tab/Enter/Escape through
        // ProcessDialogKey BEFORE any focus navigation, so the four-state model
        // can own the sequence and the TextBoxes never fall back to stock
        // Tab-order behavior. Enter means "activate the logical target": on
        // FROM/TO/APPLY it applies; on CANCEL it hides WITHOUT applying.
        protected override bool ProcessDialogKey(Keys keyData)
        {
            Keys k = keyData & Keys.KeyCode;
            if (k == Keys.Tab)
            {
                bool shift = (keyData & Keys.Shift) == Keys.Shift;
                SetFocusIndex((FocusIndex + (shift ? 3 : 1)) % 4, true);
                return true;
            }
            if (k == Keys.Enter)
            {
                if (FocusIndex == 3) { Hide(); return true; }   // Enter on CANCEL never applies
                DoApply();
                return true;
            }
            if (k == Keys.Escape)
            {
                Hide();
                return true;
            }
            return base.ProcessDialogKey(keyData);
        }

        // Moves the logical focus. 0/1 focus the real TextBox (caret visible);
        // 2/3 are the painted APPLY/CANCEL targets: the active control is
        // cleared so no TextBox shows a caret, and the painted selected state
        // (DrawButton selected) indicates the logical target instead.
        internal void SetFocusIndex(int idx, bool focusText)
        {
            FocusIndex = idx;
            if (idx == 0 && focusText) FromBox.Focus();
            else if (idx == 1 && focusText) ToBox.Focus();
            else if (ActiveControl is TextBox) ActiveControl = null;   // blur: no caret on APPLY/CANCEL
            Invalidate();
        }

        // Refresh the fields from the committed settings: reopening the editor
        // ALWAYS projects committed state -- stale validation text is cleared,
        // the normalized persisted FROM/TO are shown, and logical focus returns
        // to FROM with its text selected. CANCEL never leaves half-entered
        // values behind as the next visual state.
        internal void ShowManual()
        {
            InvalidText = null;
            FromBox.Text = S.ManualFromSec.ToString();
            ToBox.Text = S.ManualToSec.ToString();
            FromBox.SelectAll();
            FocusIndex = 0;
            FromBox.Focus();
            Invalidate();
        }

        // Apply = parse, sanitize, persist and re-arm through the owner. Empty
        // or non-numeric text keeps the editor open with a concise message; the
        // active interval is untouched. On success the fields display the
        // normalized values and the editor hides.
        void DoApply()
        {
            int f, t;
            if (!int.TryParse(FromBox.Text.Trim(), out f) || !int.TryParse(ToBox.Text.Trim(), out t))
            {
                ShowInvalid("enter numbers in both fields");
                return;
            }
            if (ApplyManual == null) { Hide(); return; }
            if (!ApplyManual(f, t))
            {
                // Persistence failed: the previous interval stays active and the
                // error was reported by the owner. Keep the editor open so the
                // user can retry or cancel.
                return;
            }
            int[] n = IntervalModel.SanitizeManual(f, t);
            FromBox.Text = n[0].ToString();
            ToBox.Text = n[1].ToString();
            Hide();
        }

        void ShowInvalid(string msg)
        {
            InvalidText = msg;
            Invalidate();
        }

        internal string InvalidText;

        // Project the CURRENT palette onto this form, including the real TextBox
        // children whose BackColor/ForeColor were assigned in the constructor --
        // OnPaint alone cannot restyle child controls.
        internal void ApplyTheme()
        {
            BackColor = Palette.BG;
            FromBox.BackColor = Palette.SURFACE;
            FromBox.ForeColor = Palette.TEXT;
            ToBox.BackColor = Palette.SURFACE;
            ToBox.ForeColor = Palette.TEXT;
            Invalidate();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (PixelFont != null) PixelFont.Dispose();
                Centered.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == Native.WM_NCHITTEST)
            {
                int raw = unchecked((int)m.LParam.ToInt64());
                int x = raw & 0xFFFF;
                int y = (raw >> 16) & 0xFFFF;
                if (x > 0x7FFF) x -= 0x10000;
                if (y > 0x7FFF) y -= 0x10000;
                Point p = PointToClient(new Point(x, y));
                if (p.Y < 20 && p.X < Width - 20)
                    m.Result = (IntPtr)Native.HTCAPTION;
            }
        }

        void DrawText(Graphics g, string s, int x, int y, Color c, int pt, bool bold = false)
        {
            using (var br = new SolidBrush(c))
                g.DrawString(s, PixelFont, br, (float)x, (float)y);
        }

        void DrawBevel(Graphics g, Rectangle r, bool raised)
        {
            Color hi = raised ? Palette.BEVEL : Palette.BDARK;
            Color lo = raised ? Palette.BDARK : Palette.BEVEL;
            using (var p1 = new Pen(hi)) g.DrawRectangle(p1, r.X, r.Y, r.Width - 1, r.Height - 1);
            using (var p2 = new Pen(lo)) g.DrawRectangle(p2, r.X + 1, r.Y + 1, r.Width - 3, r.Height - 3);
        }

        void DrawButton(Graphics g, Rectangle r, string label, bool selected)
        {
            using (var bg = new SolidBrush(selected ? Palette.COMPARE : Palette.RAISED))
                g.FillRectangle(bg, r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4);
            DrawBevel(g, r, !selected);
            using (var br = new SolidBrush(selected ? Palette.LINK : Palette.TEXT))
                g.DrawString(label, PixelFont, br, new RectangleF(r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4), Centered);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            g.SmoothingMode = SmoothingMode.None;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.CompositingQuality = CompositingQuality.HighSpeed;
            g.Clear(Palette.BG);
            Hot.Clear();

            using (var b = new SolidBrush(Palette.SURFACE)) g.FillRectangle(b, 0, 0, Width, 20);
            DrawText(g, "manual interval", 8, 4, Palette.TEXT, 12, true);
            var xr = new Rectangle(Width - 20, 0, 20, 20);
            Hot.Add(new ProblipForm.HotZone { R = xr, A = delegate() { Hide(); } });
            DrawText(g, "X", Width - 16, 4, Palette.TEXT2, 12, true);

            // FROM / TO rows: label, then the frame the parent draws around the
            // borderless TextBox, then the unit. The boxes are inset 2 px so
            // they sit inside the bevel, never on it.
            int yf = 32;
            DrawText(g, "FROM", 10, yf + 2, Palette.TEXT2, 11);
            FromFrame = new Rectangle(56, yf, 76, 22);
            DrawBevel(g, FromFrame, false);
            using (var bg = new SolidBrush(Palette.SURFACE))
                g.FillRectangle(bg, FromFrame.X + 1, FromFrame.Y + 1, FromFrame.Width - 2, FromFrame.Height - 2);
            DrawText(g, "sec", FromFrame.Right + 6, yf + 4, Palette.MUTED, 10);

            int yt = 60;
            DrawText(g, "TO", 10, yt + 2, Palette.TEXT2, 11);
            ToFrame = new Rectangle(56, yt, 76, 22);
            DrawBevel(g, ToFrame, false);
            using (var bg2 = new SolidBrush(Palette.SURFACE))
                g.FillRectangle(bg2, ToFrame.X + 1, ToFrame.Y + 1, ToFrame.Width - 2, ToFrame.Height - 2);
            DrawText(g, "sec", ToFrame.Right + 6, yt + 4, Palette.MUTED, 10);
            // Keep the real controls on their frames (they are WinForms
            // children; OnPaint cannot move them).
            FromBox.Bounds = new Rectangle(FromFrame.X + 2, FromFrame.Y + 3, FromFrame.Width - 4, 16);
            ToBox.Bounds = new Rectangle(ToFrame.X + 2, ToFrame.Y + 3, ToFrame.Width - 4, 16);

            // APPLY / CANCEL
            int yb = 90;
            int bw = 92;
            ApplyRect = new Rectangle(8, yb, bw, 22);
            Hot.Add(new ProblipForm.HotZone { R = ApplyRect, A = delegate() { DoApply(); } });
            DrawButton(g, ApplyRect, "APPLY", FocusIndex == 2);
            CancelRect = new Rectangle(ClientSize.Width - 8 - bw, yb, bw, 22);
            Hot.Add(new ProblipForm.HotZone { R = CancelRect, A = delegate() { Hide(); } });
            DrawButton(g, CancelRect, "CANCEL", FocusIndex == 3);

            // Concise validation line, clipped to the window, never overlapping
            // the buttons (it sits between TO and the button row).
            if (!string.IsNullOrEmpty(InvalidText))
            {
                int w = TextW(g, InvalidText, 9);
                if (w > Width - 16) InvalidText = InvalidText.Substring(0, Math.Max(1, InvalidText.Length - 4)) + "...";
                DrawText(g, InvalidText, 8, yb - 12, Palette.DANGERTXT, 9);
            }
        }

        int TextW(Graphics g, string s, int pt)
        {
            return (int)Math.Ceiling(g.MeasureString(s, PixelFont).Width);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left)
            {
                foreach (ProblipForm.HotZone h in Hot)
                {
                    if (h.R.Contains(e.Location)) { h.A(); return; }
                }
            }
        }
    }

    // Compact, custom-painted theme picker. One reusable instance owned by
    // Program (same ownership pattern as the statistics view), opened from both
    // the tray Themes item and the settings window's THEME line. Fifteen rows,
    // each one measured geometry: swatch + name + selection marker. Painted
    // with the ACTIVE palette; after a successful switch the same instance
    // immediately repaints in the new palette -- no restart, no new window.
    class ThemesForm : Form
    {
        Settings S;
        Func<string, bool> ApplyThemeId;   // persist+project; returns success
        List<HotZone> Hot = new List<HotZone>();
        Dictionary<int, Font> Fonts = new Dictionary<int, Font>();
        StringFormat Centered = new StringFormat();
        // Unit seam: persistence-failure notices land here instead of a modal
        // MessageBox, so regressions can observe the revert.
        System.Action<string> SettingsErrorSink;

        // Painted geometry, exposed for the layout regression: one row per
        // theme; the hit zones are exactly these rects.
        internal Rectangle[] RowRects = new Rectangle[ThemeModel.All.Length];

        class HotZone
        {
            public Rectangle R;
            public Action A;
        }

        public const int RowH = 20;
        public const int RowsTop = 30;

        public ThemesForm(Settings s, Func<string, bool> applyThemeId)
        {
            S = s; ApplyThemeId = applyThemeId;
            Centered.Alignment = StringAlignment.Center;
            Centered.LineAlignment = StringAlignment.Center;
            Text = "problip themes";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(400, RowsTop + RowH * ThemeModel.All.Length + 8);
            BackColor = Palette.BG;
            DoubleBuffered = true;
            TopMost = true;
            try { Icon = AppIcon.For(s.IcoPath, SystemInformation.IconSize.Width); }
            catch { }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                foreach (Font f in Fonts.Values) f.Dispose();
                Fonts.Clear();
                Centered.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == Native.WM_NCHITTEST)
            {
                int raw = unchecked((int)m.LParam.ToInt64());
                int x = raw & 0xFFFF;
                int y = (raw >> 16) & 0xFFFF;
                if (x > 0x7FFF) x -= 0x10000;
                if (y > 0x7FFF) y -= 0x10000;
                Point p = PointToClient(new Point(x, y));
                if (p.Y < 20 && p.X < Width - 20)
                    m.Result = (IntPtr)Native.HTCAPTION;
            }
        }

        Font F(int pt)
        {
            Font f;
            if (!Fonts.TryGetValue(pt, out f))
            {
                f = ProblipForm.MakePixelFont("Verdana", pt);
                Fonts[pt] = f;
            }
            return f;
        }

        void DrawText(Graphics g, string s, int x, int y, Color c, int pt, bool bold = false)
        {
            using (var br = new SolidBrush(c))
                g.DrawString(s, F(pt), br, (float)x, (float)y);
        }

        void DrawBevel(Graphics g, Rectangle r, bool raised)
        {
            Color hi = raised ? Palette.BEVEL : Palette.BDARK;
            Color lo = raised ? Palette.BDARK : Palette.BEVEL;
            using (var p1 = new Pen(hi)) g.DrawRectangle(p1, r.X, r.Y, r.Width - 1, r.Height - 1);
            using (var p2 = new Pen(lo)) g.DrawRectangle(p2, r.X + 1, r.Y + 1, r.Width - 3, r.Height - 3);
        }

        int TextW(Graphics g, string s, int pt)
        {
            return (int)Math.Ceiling(g.MeasureString(s, F(pt)).Width);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            g.SmoothingMode = SmoothingMode.None;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.CompositingQuality = CompositingQuality.HighSpeed;
            g.Clear(Palette.BG);
            Hot.Clear();

            using (var b = new SolidBrush(Palette.SURFACE)) g.FillRectangle(b, 0, 0, Width, 20);
            DrawText(g, "themes", 8, 4, Palette.TEXT, 12, true);
            var xr = new Rectangle(Width - 20, 0, 20, 20);
            Hot.Add(new HotZone { R = xr, A = delegate() { Hide(); } });
            DrawText(g, "X", Width - 16, 4, Palette.TEXT2, 12, true);

            // One row per theme: accent swatch (that theme's own LINK), name in
            // the ACTIVE palette's text colors, selection marker for the current
            // pick. Hit zones are exactly the painted rows.
            string currentId = ThemeModel.ById(S.ThemeId).Id;
            int y = RowsTop;
            for (int i = 0; i < ThemeModel.All.Length; i++)
            {
                ThemeEntry entry = ThemeModel.All[i];
                bool selected = entry.Id == currentId;
                RowRects[i] = new Rectangle(0, y, ClientSize.Width, RowH);
                Hot.Add(new HotZone { R = RowRects[i], A = delegate() { PickTheme(entry); } });

                // swatch: a small frame filled with THIS theme's accent.
                ProblipPalette swatchPalette = ThemeModel.PaletteFor(entry.Id);
                var sw = new Rectangle(8, y + 4, 12, 12);
                DrawBevel(g, sw, true);
                using (var sb = new SolidBrush(swatchPalette.LINK))
                    g.FillRectangle(sb, sw.X + 1, sw.Y + 1, sw.Width - 2, sw.Height - 2);

                // name: selected rows get the accent, the rest the plain text.
                DrawText(g, entry.Name, 28, y + 3, selected ? Palette.LINK : Palette.TEXT, 10, selected);

                // selection marker at the right edge, inside the client.
                if (selected) DrawText(g, "*", Width - 14, y + 3, Palette.LINK, 10, true);
                y += RowH;
            }
        }

        // One explicit user transaction: resolve, persist FIRST, only then
        // project (Settings + Palette.Current + repaint every open window via
        // Program.ApplyThemeToWindows). On failure the previous theme and
        // palette stay active and one existing-style warning reports it.
        void PickTheme(ThemeEntry entry)
        {
            if (entry == null) return;
            if (entry.Id == ThemeModel.ById(S.ThemeId).Id) return;   // already active
            if (ApplyThemeId == null || !ApplyThemeId(entry.Id))
            {
                if (SettingsErrorSink != null) SettingsErrorSink("theme");
                else MessageBox.Show(this,
                    "Could not save the theme setting.\r\nThe previous theme stays in effect.\r\n" + S.IniPath,
                    "problip", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            Invalidate();   // repaint this picker in the NEW palette, marker moved
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left)
            {
                foreach (HotZone h in Hot)
                {
                    if (h.R.Contains(e.Location)) { h.A(); return; }
                }
            }
        }
    }

    // Compact, custom-painted statistics view. Same pixel/bevel language as the
    // settings window (no DataGridView/ListView, no scrollbars), one live
    // instance owned by Program and opened from both the tray menu and the
    // clickable BLIPS line. Counts update live through the same BlipPlayed event.
    class StatsForm : Form
    {
        Settings S;
        BlipEngine Engine;
        List<HotZone> Hot = new List<HotZone>();
        Dictionary<int, Font> Fonts = new Dictionary<int, Font>();
        StringFormat Centered = new StringFormat();
        // Unit seam: a failing ShowBlipCounter write is reported here instead of
        // a modal MessageBox, so a regression can observe the revert.
        System.Action<string> SettingsErrorSink;
        // Notifies Program to repaint the (possibly open) main window when the
        // counter visibility changes. Null in unit tests is fine.
        public Action CounterChanged;

        // Painted hit zones, exposed for the UI layout regression.
        internal Rectangle CounterRect, CloseRect;
        internal Rectangle[] StatRowRects = new Rectangle[4];

        class HotZone
        {
            public Rectangle R;
            public Action A;
        }

        public StatsForm(Settings s, BlipEngine engine)
        {
            S = s; Engine = engine;
            Centered.Alignment = StringAlignment.Center;
            Centered.LineAlignment = StringAlignment.Center;
            Text = "problip statistics";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(240, 190);
            BackColor = Palette.BG;
            DoubleBuffered = true;
            TopMost = true;
            Engine.BlipPlayed += OnBlipPlayed;
            try { Icon = AppIcon.For(s.IcoPath, SystemInformation.IconSize.Width); }
            catch { }
        }

        void OnBlipPlayed(object sender, EventArgs e)
        {
            if (!IsDisposed) Invalidate();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                Engine.BlipPlayed -= OnBlipPlayed;
                foreach (Font f in Fonts.Values) f.Dispose();
                Fonts.Clear();
                Centered.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == Native.WM_NCHITTEST)
            {
                int raw = unchecked((int)m.LParam.ToInt64());
                int x = raw & 0xFFFF;
                int y = (raw >> 16) & 0xFFFF;
                if (x > 0x7FFF) x -= 0x10000;
                if (y > 0x7FFF) y -= 0x10000;
                Point p = PointToClient(new Point(x, y));
                if (p.Y < 20 && p.X < Width - 20)
                    m.Result = (IntPtr)Native.HTCAPTION;
            }
        }

        Font F(int pt)
        {
            Font f;
            if (!Fonts.TryGetValue(pt, out f))
            {
                f = ProblipForm.MakePixelFont("Verdana", pt);
                Fonts[pt] = f;
            }
            return f;
        }

        static HotZone MakeHot(Rectangle r, Action a)
        {
            HotZone h = new HotZone();
            h.R = r;
            h.A = a;
            return h;
        }

        void DrawText(Graphics g, string s, int x, int y, Color c, int pt, bool bold = false)
        {
            using (var br = new SolidBrush(c))
                g.DrawString(s, F(pt), br, (float)x, (float)y);
        }

        void DrawBevel(Graphics g, Rectangle r, bool raised)
        {
            Color hi = raised ? Palette.BEVEL : Palette.BDARK;
            Color lo = raised ? Palette.BDARK : Palette.BEVEL;
            using (var p1 = new Pen(hi)) g.DrawRectangle(p1, r.X, r.Y, r.Width - 1, r.Height - 1);
            using (var p2 = new Pen(lo)) g.DrawRectangle(p2, r.X + 1, r.Y + 1, r.Width - 3, r.Height - 3);
        }

        void DrawButton(Graphics g, Rectangle r, string label, bool selected, int pt = 10)
        {
            using (var bg = new SolidBrush(selected ? Palette.COMPARE : Palette.RAISED))
                g.FillRectangle(bg, r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4);
            DrawBevel(g, r, !selected);
            using (var br = new SolidBrush(selected ? Palette.LINK : Palette.TEXT))
                g.DrawString(label, F(pt), br, new RectangleF(r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4), Centered);
        }

        int TextW(Graphics g, string s, int pt)
        {
            return (int)Math.Ceiling(g.MeasureString(s, F(pt)).Width);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            g.SmoothingMode = SmoothingMode.None;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.CompositingQuality = CompositingQuality.HighSpeed;
            g.Clear(Palette.BG);
            Hot.Clear();

            using (var b = new SolidBrush(Palette.SURFACE)) g.FillRectangle(b, 0, 0, Width, 20);
            DrawText(g, "statistics", 8, 4, Palette.TEXT, 12, true);
            var xr = new Rectangle(Width - 20, 0, 20, 20);
            Hot.Add(MakeHot(xr, delegate() { Hide(); }));
            DrawText(g, "X", Width - 16, 4, Palette.TEXT2, 12, true);

            BlipStatsSnapshot snap = Engine.Stats.Snapshot();
            string[] labels = new string[] { "today", "this week", "this month", "total" };
            long[] vals = new long[] { snap.Today, snap.Week, snap.Month, snap.Total };
            int y = 32;
            for (int i = 0; i < labels.Length; i++)
            {
                DrawText(g, labels[i], 12, y, Palette.TEXT2, 11);
                string v = vals[i].ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
                int vw = TextW(g, v, 11);
                // Right-aligned in its own column, with room to the right edge.
                DrawText(g, v, Width - 12 - vw, y, Palette.TEXT, 11, true);
                StatRowRects[i] = new Rectangle(8, y - 2, Width - 16, 18);
                y += 22;
            }

            string counterLabel = S.ShowBlipCounter ? "[X] show counter" : "[ ] show counter";
            int cw = TextW(g, counterLabel, 10) + 14;
            CounterRect = new Rectangle(8, y + 6, cw, 22);
            Hot.Add(MakeHot(CounterRect, delegate() { ToggleShowCounter(); }));
            DrawButton(g, CounterRect, counterLabel, S.ShowBlipCounter);

            int closeW = TextW(g, "CLOSE", 10) + 24;
            CloseRect = new Rectangle(Width - 8 - closeW, y + 34, closeW, 22);
            Hot.Add(MakeHot(CloseRect, delegate() { Hide(); }));
            DrawButton(g, CloseRect, "CLOSE", false);
        }

        // Persists the counter-visibility preference with the established
        // explicit-setting transaction semantics: on a failed write the value is
        // restored, the UI stays truthful, and the failure is reported once.
        // This is application state, never statistics state.
        internal void ToggleShowCounter()
        {
            bool previous = S.ShowBlipCounter;
            bool next = !previous;
            S.ShowBlipCounter = next;
            try
            {
                S.Save("ShowBlipCounter", next ? "1" : "0");
            }
            catch (System.IO.IOException)
            {
                S.ShowBlipCounter = previous;
                NotifySettingsError();
                Invalidate();
                return;
            }
            if (CounterChanged != null) CounterChanged();
            Invalidate();
        }

        void NotifySettingsError()
        {
            if (SettingsErrorSink != null) { SettingsErrorSink("ShowBlipCounter"); return; }
            MessageBox.Show(this,
                "Could not save the show-counter setting.\r\nThe previous value stays in effect.\r\n" + S.IniPath,
                "problip", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left)
            {
                foreach (HotZone h in Hot)
                {
                    if (h.R.Contains(e.Location)) { h.A(); return; }
                }
            }
        }
    }

    static class Program
    {
        static ProblipForm _form;
        static StatsForm _statsForm;
        static ManualIntervalForm _manualForm;
        static ThemesForm _themesForm;

        [STAThread]
        static void Main()
        {
            bool createdNew;
            using (var mutex = new System.Threading.Mutex(true, "Local\\ProblipApp", out createdNew))
            {
                if (!createdNew) return;

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                string dir = AppDomain.CurrentDomain.BaseDirectory;
                Settings s = new Settings(dir);
                s.Load();

                BlipEngine engine = new BlipEngine(s);
                // Startup honors the remembered user intent: RunOnLaunch=1
                // (the old-INI and fresh-install default) arms the beeper;
                // RunOnLaunch=0 leaves a resident but paused tray app. A broken
                // asset with RunOnLaunch=1 lands in ERR via Start() itself --
                // never fake ON, never rewrite the preference.
                RunState.ApplyLaunch(s, engine);

                // Activate the persisted theme BEFORE any window is built, so
                // even the first paint uses the right palette. Load() already
                // normalized the id (unknown/legacy -> Golden Default).
                Palette.Current = ThemeModel.PaletteFor(s.ThemeId);

                NotifyIcon tray = new NotifyIcon();
                tray.Icon = AppIcon.For(s.IcoPath, SystemInformation.SmallIconSize.Width);
                tray.Text = TrayText(engine);
                ContextMenuStrip menu = new ContextMenuStrip();
                menu.Items.Add("Open settings", null, delegate(object o, EventArgs e) { ShowForm(s, engine, tray); });
                // Same single statistics view as the clickable BLIPS line.
                menu.Items.Add("Statistics", null, delegate(object o, EventArgs e) { ShowStats(s, engine); });
                // Same single theme picker as the settings window's THEME line.
                menu.Items.Add("Themes", null, delegate(object o, EventArgs e) { ShowThemes(s); });
                menu.Items.Add(new ToolStripSeparator());
                // Preview is stateless: it never flips ON/OFF, never re-arms the
                // pending wait. A failed preview surfaces through the existing
                // tray failure caption, and the window carries the detail.
                menu.Items.Add("Test blip", null, delegate(object o, EventArgs e) { engine.Preview(); });
                // Start/Stop are held (not anonymous throwaways) so availability
                // can track state: ON -> Start disabled; OFF/ERR -> Start enabled
                // (the explicit recovery action), Stop disabled in OFF/ERR.
                ToolStripMenuItem miStart = (ToolStripMenuItem)menu.Items.Add("Start", null, delegate(object o, EventArgs e) { RunState.RequestStart(s, engine); });
                ToolStripMenuItem miStop = (ToolStripMenuItem)menu.Items.Add("Stop", null, delegate(object o, EventArgs e) { RunState.RequestStop(s, engine); });
                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add("Exit", null, delegate(object o, EventArgs e)
                {
                    // Cleanup flushes any pending statistics before teardown.
                    engine.Cleanup();
                    if (_statsForm != null) { try { _statsForm.Dispose(); } catch { } _statsForm = null; }
                    if (_manualForm != null) { try { _manualForm.Dispose(); } catch { } _manualForm = null; }
                    if (_themesForm != null) { try { _themesForm.Dispose(); } catch { } _themesForm = null; }
                    tray.Visible = false;
                    Application.Exit();
                });
                tray.ContextMenuStrip = menu;
                tray.Visible = true;
                tray.DoubleClick += delegate(object o, EventArgs e) { ShowForm(s, engine, tray); };

                // Tray follows runtime state without a user click: any
                // observable transition (ON/OFF/ERR) refreshes the caption and
                // the Start/Stop availability. The settings form subscribes on
                // its own lifetime; this handler lives for the whole run.
                EventHandler onState = delegate(object o, EventArgs e)
                {
                    try
                    {
                        tray.Text = TrayText(engine);
                        miStart.Enabled = !engine.IsOn || engine.IsBroken;
                        miStop.Enabled = engine.IsOn && !engine.IsBroken;
                    }
                    catch { }
                };
                engine.StateChanged += onState;
                onState(null, EventArgs.Empty);

                // always fix the autostart entry on every boot: the INI is the
                // authority, the Run key is its projection.
                try
                {
                    if (s.AutoStart) AutoStart.Set(AutoStart.RunKeyPath, Application.ExecutablePath);
                    else AutoStart.Clear(AutoStart.RunKeyPath);
                }
                catch { }

                Application.Run();
                engine.Cleanup();
                if (_statsForm != null) { try { _statsForm.Dispose(); } catch { } _statsForm = null; }
                if (_manualForm != null) { try { _manualForm.Dispose(); } catch { } _manualForm = null; }
                if (_themesForm != null) { try { _themesForm.Dispose(); } catch { } _themesForm = null; }
                if (menu != null) menu.Dispose();
                if (tray != null)
                {
                    tray.Visible = false;
                    tray.Dispose();
                }
                // tray.Icon is a cloned Icon the NotifyIcon does not own.
                if (tray != null && tray.Icon != null) tray.Icon.Dispose();
            }
        }

        // NotifyIcon.Text rejects anything over 63 characters, so the failure
        // reason is named but the asset detail stays in the window.
        static string TrayText(BlipEngine engine)
        {
            return engine.TrayCaption;
        }

        static void ShowForm(Settings s, BlipEngine engine, NotifyIcon tray)
        {
            if (_form == null || _form.IsDisposed)
            {
                _form = new ProblipForm(s, engine, tray);
                // The clickable BLIPS line opens the same single statistics view
                // the tray menu owns.
                _form.OpenStatistics = delegate() { ShowStats(s, engine); };
                // The MANUAL button opens the one reusable manual-interval
                // editor; APPLY routes through ProblipForm.ApplyManual.
                _form.OpenManual = delegate() { ShowManual(s, _form); };
                // The THEME line opens the one reusable theme picker.
                _form.OpenThemes = delegate() { ShowThemes(s); };
                _form.FormClosing += delegate(object o, FormClosingEventArgs e)
                {
                    if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; _form.Hide(); }
                };
            }
            _form.Show();
            _form.Activate();
        }        // One live theme picker, owned like the statistics view: both the tray
        // Themes item and the settings window's THEME line open the SAME
        // instance. The switch transaction itself is ApplyThemeId below.
        static void ShowThemes(Settings s)
        {
            if (_themesForm == null || _themesForm.IsDisposed)
            {
                _themesForm = new ThemesForm(s, delegate(string themeId)
                {
                    return ApplyThemeId(s, themeId);
                });
                _themesForm.FormClosing += delegate(object o, FormClosingEventArgs e)
                {
                    if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; _themesForm.Hide(); }
                };
            }
            _themesForm.Show();
            _themesForm.Activate();
        }

        // The ONE theme-switch transaction, shared by every entry point.
        // Persist first, project second: only a verified INI write moves
        // Settings.ThemeId and Palette.Current, then every open reusable window
        // is repainted. A failed write keeps the previous theme/palette active
        // and returns false (the caller reports it) -- the session is never left
        // visually changed but unsaved. Pure visual state: the engine's
        // interval, phase, schedule and statistics are untouched.
        static bool ApplyThemeId(Settings s, string themeId)
        {
            ThemeEntry entry = ThemeModel.ById(themeId);   // resolve valid id
            try
            {
                s.Save("ThemeId", entry.Id);
            }
            catch (System.IO.IOException)
            {
                return false;
            }
            s.ThemeId = entry.Id;
            Palette.Current = ThemeModel.PaletteFor(entry.Id);
            ApplyThemeToWindows();
            return true;
        }

        // Repaints every open/hidden reusable window without recreating any of
        // them. ManualIntervalForm carries real TextBox children, so its
        // ApplyTheme also restyles those; the others paint everything.
        internal static void ApplyThemeToWindows()
        {
            if (_form != null && !_form.IsDisposed) _form.ApplyTheme();
            if (_manualForm != null && !_manualForm.IsDisposed) _manualForm.ApplyTheme();
            if (_statsForm != null && !_statsForm.IsDisposed) { _statsForm.BackColor = Palette.BG; _statsForm.Invalidate(); }
            if (_themesForm != null && !_themesForm.IsDisposed) { _themesForm.BackColor = Palette.BG; _themesForm.Invalidate(); }
        }

        // One live manual-interval editor, owned like the statistics view: a
        // second open reuses and re-populates the same instance, never
        // duplicates it. Opening it is not a scheduling event.
        static void ShowManual(Settings s, ProblipForm owner)
        {
            if (_manualForm == null || _manualForm.IsDisposed)
            {
                _manualForm = new ManualIntervalForm(s, delegate(int fromSec, int toSec)
                {
                    return owner.ApplyManual(fromSec, toSec);
                });
                _manualForm.FormClosing += delegate(object o, FormClosingEventArgs e)
                {
                    if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; _manualForm.Hide(); }
                };
            }
            _manualForm.ShowManual();
            _manualForm.Show();
            _manualForm.Activate();
        }

        // One live statistics instance, owned like the settings window: a second
        // open reuses and activates it, never duplicates it.
        static void ShowStats(Settings s, BlipEngine engine)
        {
            if (_statsForm == null || _statsForm.IsDisposed)
            {
                _statsForm = new StatsForm(s, engine);
                _statsForm.CounterChanged = delegate()
                {
                    if (_form != null && !_form.IsDisposed) _form.Invalidate();
                };
                _statsForm.FormClosing += delegate(object o, FormClosingEventArgs e)
                {
                    if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; _statsForm.Hide(); }
                };
            }
            _statsForm.Show();
            _statsForm.Activate();
        }
    }
}
