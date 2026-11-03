import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Preview, PreviewErrorBoundary, send } from "./Preview";
import type { RenderRequest } from "./protocol";
import { setAppearance } from "./appearance";
import { setViewportInsets } from "./viewport";
import { CommentHighlightController } from "./commentHighlights";
import "../../../../gistpad.dev/src/features/markdown/index.css";
import "./style.css";

const root = createRoot(document.getElementById("root")!);
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
let comments: CommentHighlightController | undefined;
window.gistpadPreview = Object.freeze({
  setAppearance,
  setViewportInsets,
  commentSegments() {
    if (!comments) throw new Error("There is no rendered document.");
    return comments.catalog();
  },
  commentSelection() {
    if (!comments) throw new Error("There is no rendered document.");
    return comments.selection();
  },
  setCommentHighlights(value) {
    if (!comments) throw new Error("There is no rendered document.");
    comments.setHighlights(value);
  },
  render(request: RenderRequest) {
    comments = new CommentHighlightController(request, (message) =>
      window.webkit?.messageHandlers?.gistpadComments?.postMessage(message));
    root.render(
      <QueryClientProvider client={queryClient}>
        <PreviewErrorBoundary key={request.documentID} request={request}>
          <Preview request={request} comments={comments} />
        </PreviewErrorBoundary>
      </QueryClientProvider>,
    );
  },
});
send({ type: "ready" });
