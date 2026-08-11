"use client";

import { SITE_THEME_OPTIONS, type SiteLanguage, type SiteTheme } from "./site-settings";

type ThemePickerProps = {
  language: SiteLanguage;
  value: SiteTheme;
  compact?: boolean;
  onChange: (theme: SiteTheme) => void;
};

export default function ThemePicker({ language, value, compact = false, onChange }: ThemePickerProps) {
  const label = language === "zh" ? "选择主题" : "Choose a theme";
  const selectedOption = SITE_THEME_OPTIONS.find((option) => option.value === value) ?? SITE_THEME_OPTIONS[0];
  const renderOption = (option: (typeof SITE_THEME_OPTIONS)[number]) => {
    const optionLabel = option.label[language];
    const optionDescription = option.description[language];
    return (
      <button
        className={`theme-option ${value === option.value ? "selected" : ""}`}
        type="button"
        key={option.value}
        aria-label={`${optionLabel} · ${optionDescription}`}
        aria-pressed={value === option.value}
        title={`${optionLabel} · ${optionDescription}`}
        onClick={(event) => {
          onChange(option.value);
          if (compact) event.currentTarget.closest("details")?.removeAttribute("open");
        }}
      >
        <span className={`theme-swatch theme-swatch-${option.value}`} aria-hidden="true" />
        <span className="theme-option-copy">
          <strong>{optionLabel}</strong>
          <small>{optionDescription}</small>
        </span>
      </button>
    );
  };

  if (compact) {
    return (
      <details className="theme-picker theme-picker-compact">
        <summary className="theme-current" aria-label={label} title={`${selectedOption.label[language]} · ${selectedOption.description[language]}`}>
          <span className={`theme-swatch theme-swatch-${selectedOption.value}`} aria-hidden="true" />
        </summary>
        <div className="theme-menu" role="group" aria-label={label}>
          {SITE_THEME_OPTIONS.map(renderOption)}
        </div>
      </details>
    );
  }

  return (
    <div className="theme-picker theme-picker-full" role="group" aria-label={label}>
      {SITE_THEME_OPTIONS.map(renderOption)}
    </div>
  );
}
