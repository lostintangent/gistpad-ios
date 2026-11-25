import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Preview, PreviewErrorBoundary } from "./Preview";
import { send, type RenderRequest } from "./protocol";
import { setAppearance } from "./appearance";
import { CommentAnnotationController } from "./commentAnnotations";
import "../../../../gistpad.dev/src/features/markdown/index.css";
import "./style.css";

const root = createRoot(document.getElementById("root")!);
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
// Native asks about comments only after the page reports a render.
let comments: CommentAnnotationController;
window.gistpadPreview = Object.freeze({
  setAppearance,
  commentSegments: () => comments.catalog(),
  commentSelection: () => comments.selection(),
  setCommentAnnotations: (value) => comments.setAnnotations(value),
  render(request: RenderRequest) {
    comments = new CommentAnnotationController(request);
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
