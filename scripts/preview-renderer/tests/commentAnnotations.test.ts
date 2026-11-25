import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { Root } from "hast";
import { CommentAnnotationController, CommentText } from "../src/commentAnnotations";
import type { RenderRequest } from "../src/protocol";

const request: RenderRequest = {
  generation: 1, markdown: "A native note", allowsTaskEdits: true,
};

describe("comment annotations", () => {
  test("selected overlap partitions share one visual run without merging thread targets", () => {
    const controller = new CommentAnnotationController(request);
    controller.catalogPlugin()({ type: "root", children: [{ type: "text", value: request.markdown }] });
    controller.setAnnotations({
      annotations: [
        { segment: 0, start: 2, end: 8, threadIDs: [10] },
        { segment: 0, start: 8, end: 13, threadIDs: [10, 20] },
      ],
      selectedThreadID: 10, showsAll: true, reveal: null, accent: "#FACC15",
    });
    const html = renderToStaticMarkup(createElement(CommentText, {
      controller, segment: 0, text: request.markdown,
    }));
    expect(html.match(/class="comment-selected-run"/g)).toHaveLength(1);
    expect(html.match(/role="button"/g)).toHaveLength(2);
    expect(html).toContain('data-comment-ids="10"');
    expect(html).toContain('data-comment-ids="10 20"');
    expect(html.replace(/<[^>]*>/g, "")).toBe(request.markdown);
  });

  test("each reveal claims its thread's first passage once, and selection alone never reveals", () => {
    const controller = new CommentAnnotationController(request);
    const first = { segment: 0, start: 2, end: 8, threadIDs: [10] };
    const shared = { segment: 0, start: 8, end: 13, threadIDs: [10, 20] };
    const state = {
      annotations: [first, shared], selectedThreadID: 10, showsAll: true, reveal: null, accent: "#FACC15",
    };
    controller.setAnnotations(state);
    expect(controller.claimReveal(first)).toBe(false);
    controller.setAnnotations({ ...state, reveal: { threadID: 10, revision: 1 } });
    expect(controller.claimReveal(shared)).toBe(false);
    expect(controller.claimReveal(first)).toBe(true);
    expect(controller.claimReveal(first)).toBe(false);
    controller.setAnnotations({ ...state, reveal: { threadID: 20, revision: 2 } });
    expect(controller.claimReveal(shared)).toBe(true);
  });

  test("catalog keeps individual text nodes in document order and excludes code and SVG", () => {
    const tree: Root = {
      type: "root", children: [{
        type: "element", tagName: "p", properties: {}, children: [
          { type: "text", value: "Before " },
          { type: "element", tagName: "strong", properties: {}, children: [{ type: "text", value: "native" }] },
          { type: "text", value: " after" },
          { type: "element", tagName: "code", properties: {}, children: [{ type: "text", value: "inline" }] },
        ],
      }, ...["pre", "svg"].map((tagName) => ({
        type: "element" as const, tagName, properties: {},
        children: [{ type: "text" as const, value: "excluded" }],
      }))],
    };
    const controller = new CommentAnnotationController(request);
    controller.catalogPlugin()(tree);
    expect(controller.catalog()).toEqual(["Before ", "native", " after"]);
  });

  test("table whitespace stays a text node instead of becoming invalid span children", () => {
    const tree: Root = {
      type: "root", children: [{
        type: "element", tagName: "table", properties: {}, children: [
          { type: "text", value: "\n" },
          { type: "element", tagName: "tbody", properties: {}, children: [{
            type: "element", tagName: "tr", properties: {}, children: [{
              type: "element", tagName: "td", properties: {}, children: [{ type: "text", value: "native" }],
            }],
          }] },
        ],
      }],
    };
    const controller = new CommentAnnotationController(request);
    controller.catalogPlugin()(tree);
    const table = tree.children[0]!;
    expect(table.type === "element" && table.children[0]!.type).toBe("text");
    expect(controller.catalog()).toEqual(["\n", "native"]);
  });
});
