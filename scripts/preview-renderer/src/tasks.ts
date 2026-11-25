import type { Root as MarkdownRoot } from "mdast";
import type { Root as HTMLRoot, Element } from "hast";
import { visit } from "unist-util-visit";
import { toString } from "hast-util-to-string";

// Each checkbox carries the UTF-16 location of its source marker, which is how the app names the task.
export function taskMarkerPlugins(markdown: string) {
  const markers = new Map<number, number>();
  return {
    remark: () => (tree: MarkdownRoot) => {
      visit(tree, "listItem", (node) => {
        if (typeof node.checked !== "boolean") return;
        const start = node.position?.start.offset;
        if (start === undefined) return;
        const line = markdown.slice(start).split(/\r?\n/, 1)[0];
        const marker = /^(?:[-+*]|\d+[.)])[ \t]+\[[ xX]\](?=[ \t]|$)/.exec(line);
        if (!marker) throw new Error("Task has no addressable source marker");
        markers.set(start, start + marker[0].length - 3);
      });
    },
    rehype: () => (tree: HTMLRoot) => {
      visit(tree, "element", (node) => {
        if (node.tagName !== "li") return;
        const start = node.position?.start.offset;
        const location = start === undefined ? undefined : markers.get(start);
        if (location === undefined) return;
        function annotate(element: Element) {
          for (const child of element.children) {
            if (child.type !== "element" || child.tagName === "ul" || child.tagName === "ol") continue;
            if (child.tagName === "input" && child.properties.type === "checkbox") {
              child.properties.dataTaskLocation = location;
              child.properties.dataTaskLabel = node.children
                .filter((child) => child.type !== "element" || (child.tagName !== "ul" && child.tagName !== "ol"))
                .map((child) => toString(child)).join("").trim();
              return true;
            }
            if (annotate(child)) return true;
          }
          return false;
        }
        annotate(node);
      });
    },
    markers,
  };
}
