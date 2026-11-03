import { expect, test } from "bun:test";
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkRehype from "remark-rehype";
import rehypeRaw from "rehype-raw";
import rehypeSanitize from "rehype-sanitize";
import { visit } from "unist-util-visit";
import { taskRangePlugins } from "../src/tasks";

test("task ranges address the correct duplicate after emoji and CRLF", async () => {
  const markdown = "👩🏽‍💻 café é\r\n\r\n- [ ] Same\r\n- [x] Same\r\n  - [ ] Nested\r\n\r\n> - [X] Quoted\r\n\r\n1. [ ] Ordered\r\n";
  const plugins = taskRangePlugins(markdown);
  const processor = unified().use(remarkParse).use(remarkGfm).use(plugins.remark)
    .use(remarkRehype).use(plugins.rehype);
  const tree = await processor.run(processor.parse(markdown));
  const ranges = [...plugins.ranges.values()];
  expect(ranges).toHaveLength(5);
  expect(ranges.map((edit) => markdown.slice(edit.location, edit.location + edit.length))).toEqual([
    "[ ]", "[x]", "[ ]", "[X]", "[ ]",
  ]);
  const second = ranges[1];
  expect(markdown.slice(0, second.location) + second.replacementMarker +
    markdown.slice(second.location + second.length)).toBe(markdown.replace("[x]", "[ ]"));
  const annotated: number[] = [];
  visit(tree, "element", (node) => {
    if (typeof node.properties.dataTaskLocation === "number") annotated.push(node.properties.dataTaskLocation);
  });
  expect(annotated).toEqual(ranges.map((edit) => edit.location));
});

test("raw HTML cannot forge an editable task range", async () => {
  const markdown = '<input type="checkbox" data-task-location="0" data-task-expected="[ ]">\n\n- [ ] Real';
  const plugins = taskRangePlugins(markdown);
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

