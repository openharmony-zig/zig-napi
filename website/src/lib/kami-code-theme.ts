/**
 * Build-time syntax highlighting theme.
 *
 * Kami allows exactly one screen surface where more than one hue is legal:
 * the dark code frame (`--shot-bg: #141318`), with the token palette listed
 * in `references/design.md` «Code Block». Code is highlighted during the
 * build, so no highlighter ships to the browser and the pages stay readable
 * with JavaScript disabled.
 */

type CodeTheme = {
  name: string;
  type: "dark" | "light";
  colors: Record<string, string>;
  settings: Array<{
    scope?: string | string[];
    settings: { foreground?: string; fontStyle?: string };
  }>;
};

export const kamiCodeTheme: CodeTheme = {
  name: "kami-dark",
  type: "dark",
  colors: {
    "editor.background": "#141318",
    "editor.foreground": "#e8e6dc",
  },
  settings: [
    { settings: { foreground: "#e8e6dc" } },
    {
      scope: ["comment", "punctuation.definition.comment"],
      settings: { foreground: "#79756a", fontStyle: "italic" },
    },
    {
      scope: [
        "keyword",
        "keyword.control",
        "keyword.operator.assignment",
        "storage",
        "storage.type",
        "storage.modifier",
        "punctuation.definition.keyword",
      ],
      settings: { foreground: "#84aad6" },
    },
    {
      scope: [
        "string",
        "string.quoted",
        "punctuation.definition.string",
        "constant.other.symbol",
        "constant.character.escape",
      ],
      settings: { foreground: "#8cbb91" },
    },
    {
      scope: ["constant.numeric", "constant.language", "constant.other"],
      settings: { foreground: "#cbab86" },
    },
    {
      scope: [
        "entity.name.function",
        "entity.name.type",
        "entity.name.class",
        "entity.name.tag",
        "entity.name.section",
        "support.class",
        "support.type",
      ],
      settings: { foreground: "#d6c78c" },
    },
    {
      scope: [
        "support.function",
        "support.function.builtin",
        "variable.language",
        "support.constant",
        "keyword.operator",
      ],
      settings: { foreground: "#b59ccd" },
    },
  ],
};
