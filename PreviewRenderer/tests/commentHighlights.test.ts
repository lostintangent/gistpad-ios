import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { Root } from "hast";
import { CommentHighlightController, CommentText } from "../src/commentHighlights";
import type { RenderRequest } from "../src/protocol";

const request: RenderRequest = {
  documentID: "comments-fixture", generation: 1, markdown: "A native note", allowsTaskEdits: true,
};

describe("comment highlights", () => {
  test("selected overlap partitions share one visual run without merging thread targets", () => {
    const controller = new CommentHighlightController(request, () => {});
    controller.catalogPlugin()({ type: "root", children: [{ type: "text", value: request.markdown }] });
    controller.setHighlights({
      highlights: [
        { segment: 0, start: 2, end: 8, commentIDs: [10] },
        { segment: 0, start: 8, end: 13, commentIDs: [10, 20] },
      ],
      selectedCommentID: 10, revealRevision: 0,
      showsInlineComments: true, allowsInteraction: true, accent: "#FACC15",
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
    const controller = new CommentHighlightController(request, () => {});
    controller.catalogPlugin()(tree);
    expect(controller.catalog().segments).toEqual(["Before ", "native", " after"]);
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
    const controller = new CommentHighlightController(request, () => {});
    controller.catalogPlugin()(tree);
    const table = tree.children[0]!;
    expect(table.type === "element" && table.children[0]!.type).toBe("text");
    expect(controller.catalog().segments).toEqual(["\n", "native"]);
  });
});
