import { expect, test } from "bun:test";
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkRehype from "remark-rehype";
import rehypeRaw from "rehype-raw";
import rehypeSanitize from "rehype-sanitize";
import { visit } from "unist-util-visit";
import { taskMarkerPlugins } from "../src/tasks";

test("task markers address the correct duplicate after emoji and CRLF", async () => {
  const markdown = "👩🏽‍💻 café é\r\n\r\n- [ ] Same\r\n- [x] Same\r\n  - [ ] Nested\r\n\r\n> - [X] Quoted\r\n\r\n1. [ ] Ordered\r\n";
  const plugins = taskMarkerPlugins(markdown);
  const processor = unified().use(remarkParse).use(remarkGfm).use(plugins.remark)
    .use(remarkRehype).use(plugins.rehype);
  const tree = await processor.run(processor.parse(markdown));
  const markers = [...plugins.markers.values()];
  expect(markers.map((location) => markdown.slice(location, location + 3))).toEqual([
    "[ ]", "[x]", "[ ]", "[X]", "[ ]",
  ]);
  expect(markers[1]).toBe(markdown.indexOf("[x]"));
  const annotated: number[] = [];
  visit(tree, "element", (node) => {
    if (typeof node.properties.dataTaskLocation === "number") annotated.push(node.properties.dataTaskLocation);
  });
  expect(annotated).toEqual(markers);
});

test("raw HTML cannot forge an editable task", async () => {
  const markdown = '<input type="checkbox" data-task-location="0">\n\n- [ ] Real';
  const plugins = taskMarkerPlugins(markdown);
  const processor = unified().use(remarkParse).use(remarkGfm).use(plugins.remark)
    .use(remarkRehype, { allowDangerousHtml: true }).use(rehypeRaw)
    .use(rehypeSanitize).use(plugins.rehype);
  const tree = await processor.run(processor.parse(markdown));
  const locations: unknown[] = [];
  visit(tree, "element", (node) => {
    if (node.tagName === "input") locations.push(node.properties.dataTaskLocation);
  });
  expect(locations).toEqual([undefined, markdown.lastIndexOf("[ ]")]);
});

