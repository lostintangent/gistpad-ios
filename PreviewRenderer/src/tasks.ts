import type { Root as MarkdownRoot } from "mdast";
import type { Root as HTMLRoot, Element } from "hast";
import { visit } from "unist-util-visit";
import type { TaskEdit } from "./protocol";

export function taskRangePlugins(markdown: string) {
  const ranges = new Map<number, TaskEdit>();
  return {
    remark: () => (tree: MarkdownRoot) => {
      visit(tree, "listItem", (node) => {
        if (typeof node.checked !== "boolean") return;
        const start = node.position?.start.offset;
        if (start === undefined) return;
        const line = markdown.slice(start).split(/\r?\n/, 1)[0];
        const marker = /^(?:[-+*]|\d+[.)])[ \t]+(\[[ xX]\])(?=[ \t]|$)/.exec(line);
        if (!marker) throw new Error("Task has no addressable source marker");
        const expectedMarker = marker[1] as TaskEdit["expectedMarker"];
        ranges.set(start, {
          location: start + marker[0].length - 3,
          length: 3,
          expectedMarker,
          replacementMarker: node.checked ? "[ ]" : "[x]",
        });
      });
    },
    rehype: () => (tree: HTMLRoot) => {
      visit(tree, "element", (node) => {
        if (node.tagName !== "li") return;
        const start = node.position?.start.offset;
        const edit = start === undefined ? undefined : ranges.get(start);
        if (!edit) return;
        function annotate(element: Element) {
          for (const child of element.children) {
            if (child.type !== "element" || child.tagName === "ul" || child.tagName === "ol") continue;
            if (child.tagName === "input" && child.properties.type === "checkbox") {
              child.properties.dataTaskLocation = edit!.location;
              child.properties.dataTaskExpected = edit!.expectedMarker;
              child.properties.dataTaskReplacement = edit!.replacementMarker;
              return true;
            }
            if (annotate(child)) return true;
          }
          return false;
        }
        annotate(node);
      });
    },
    ranges,
  };
}
