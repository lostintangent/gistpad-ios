import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Preview, PreviewErrorBoundary } from "./Preview";
import { send, type RenderRequest } from "./protocol";
import { setAppearance } from "./appearance";
import { CommentHighlightController } from "./commentHighlights";
import "../../../../gistpad.dev/src/features/markdown/index.css";
import "./style.css";

const root = createRoot(document.getElementById("root")!);
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
// Native asks about comments only after the page reports a render.
let comments: CommentHighlightController;
window.gistpadPreview = Object.freeze({
  setAppearance,
  commentSegments: () => comments.catalog(),
  commentSelection: () => comments.selection(),
  setCommentHighlights: (value) => comments.setHighlights(value),
  render(request: RenderRequest) {
    comments = new CommentHighlightController(request);
    root.render(
      <QueryClientProvider client={queryClient}>
        <PreviewErrorBoundary request={request}>
          <Preview request={request} comments={comments} />
        </PreviewErrorBoundary>
      </QueryClientProvider>,
    );
  },
});
send({ type: "ready" });
