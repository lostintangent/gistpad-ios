import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Preview, PreviewErrorBoundary, send } from "./Preview";
import { isRenderRequest } from "./protocol";
import { setAppearance } from "./appearance";
import { setTaskEditingEnabled } from "./taskEditing";
import { setViewportInsets } from "./viewport";
import { CommentHighlightController } from "./commentHighlights";
import "../../../gistpad.dev/src/features/markdown/index.css";
import "./style.css";

const root = createRoot(document.getElementById("root")!);
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
let comments: CommentHighlightController | undefined;
window.gistpadPreview = Object.freeze({
  setAppearance,
  setTaskEditingEnabled,
  setViewportInsets,
  commentSegments() {
    if (!comments) throw new Error("There is no rendered document.");
    return comments.catalog();
  },
  commentSelection() {
    if (!comments) throw new Error("There is no rendered document.");
    return comments.selection();
  },
  setCommentHighlights(value: unknown) {
    if (!comments) throw new Error("There is no rendered document.");
    comments.setHighlights(value);
  },
  render(request: unknown) {
    if (!isRenderRequest(request)) throw new TypeError("Invalid preview render request");
    comments = new CommentHighlightController(request, (message) => {
      window.webkit?.messageHandlers?.gistpadComments?.postMessage(message);
      window.dispatchEvent(new CustomEvent("gistpad-comment-message", { detail: message }));
    });
    root.render(
      <QueryClientProvider client={queryClient}>
        <PreviewErrorBoundary key={request.documentID} request={request}>
          <Preview request={request} comments={comments} />
        </PreviewErrorBoundary>
      </QueryClientProvider>,
    );
  },
});
send({ type: "ready", version: 1 });
