export function adaptMermaid(source: string, themeModule: string): string {
  const replacements = [
    ['theme: isDarkMode ? "dark" : "default",', "...nativeDiagramTheme(),"],
    ['queryKey: ["mermaid", content, isDarkMode],', 'queryKey: ["mermaid", content, isDarkMode, nativeDiagramThemeKey()],'],
  ];
  for (const [before, after] of replacements) {
    if (source.split(before).length !== 2) {
      throw new Error("Web Mermaid configuration changed. Review its native presentation adapter.");
    }
    source = source.replace(before, after);
  }
  return `import { nativeDiagramTheme, nativeDiagramThemeKey } from ${JSON.stringify(themeModule)};\n` + source;
}
