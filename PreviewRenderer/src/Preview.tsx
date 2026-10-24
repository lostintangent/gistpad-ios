import { Component, useEffect, useMemo, useState, type ReactNode } from "react";
import ReactMarkdown, { type Components, type Options } from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkGithubAlerts from "remark-github-alerts";
import remarkFrontmatter from "remark-frontmatter";
import rehypeRaw from "rehype-raw";
import rehypeSlug from "rehype-slug";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import emojiData from "@emoji-mart/data/sets/15/native.json";
import remarkInlineSyntax from "../../../gistpad.dev/src/features/markdown/remarkInlineSyntax";
import rehypeToc from "@gistpad/rehype-toc";
import Mermaid from "../../../gistpad.dev/src/features/markdown/Mermaid";
import { taskRangePlugins } from "./tasks";
import type { PreviewMessage, RenderRequest, TaskEdit } from "./protocol";

const emojis = new Map(
  Object.entries(emojiData.emojis).map(([id, emoji]) => [id, emoji.skins[0]?.native ?? ""]),
);
const schema = {
  ...defaultSchema,
  clobberPrefix: "",
  attributes: {
    ...defaultSchema.attributes,
    a: [...(defaultSchema.attributes?.a ?? []), "dataWikilink", "dataBookmark"],
    span: [...(defaultSchema.attributes?.span ?? []), "dataSpoiler", "className"],
    div: [...(defaultSchema.attributes?.div ?? []), "className"],
    blockquote: [...(defaultSchema.attributes?.blockquote ?? []), "className"],
    svg: ["viewBox", "width", "height", "fill", "ariaHidden"],
    path: ["d"],
  },
  tagNames: [...(defaultSchema.tagNames ?? []), "svg", "path"],
  protocols: {
    ...defaultSchema.protocols,
    src: ["https", "http", "data"],
  },
};

export function send(message: PreviewMessage) {
  window.webkit?.messageHandlers?.gistpadPreview?.postMessage(message);
  window.dispatchEvent(new CustomEvent("gistpad-preview-message", { detail: message }));
}

function Spoiler({ children }: { children: ReactNode }) {
  const [revealed, setRevealed] = useState(false);
  return (
    <button className="spoiler" aria-expanded={revealed} onClick={() => setRevealed(!revealed)}>
      {revealed ? children : "Reveal spoiler"}
    </button>
  );
}

export class PreviewErrorBoundary extends Component<
  { request: RenderRequest; children: ReactNode },
  { error: boolean }
> {
  state = { error: false };
  static getDerivedStateFromError() {
    return { error: true };
  }
  componentDidCatch(error: Error) {
    send({ ...identity(this.props.request), type: "failure", message: error.message.slice(0, 512) });
  }
  componentDidUpdate(previous: { request: RenderRequest }) {
    if (this.state.error && previous.request.generation !== this.props.request.generation) {
      this.setState({ error: false });
    }
  }
  render() {
    return this.state.error ? <p role="alert">This preview could not be rendered.</p> : this.props.children;
  }
}

export function identity(request: RenderRequest) {
  return { version: request.version, documentID: request.documentID, generation: request.generation };
}

export function Preview({ request }: { request: RenderRequest }) {
  const taskPlugins = useMemo(() => taskRangePlugins(request.markdown), [request]);
  const components = useMemo<Components>(() => {
    const link = (kind: "external" | "wikilink" | "anchor", target: string) => {
      if (kind === "anchor") {
        const element = document.getElementById(target);
        element?.scrollIntoView({ block: "start" });
        element?.setAttribute("tabindex", "-1");
        element?.focus({ preventScroll: true });
      }
      send({ ...identity(request), type: "link", kind, target });
    };
    return {
      a({ href, children, node, ...props }) {
        const wikilink = node?.properties.dataWikilink;
        const bookmark = node?.properties.dataBookmark;
        if (typeof wikilink === "string") {
          return <button className="wikilink" onClick={() => link("wikilink", wikilink)}>{children}</button>;
        }
        if (typeof bookmark === "string") {
          return <button id={bookmark} className="bookmark" aria-label={`Bookmark ${bookmark}`} onClick={() => link("anchor", bookmark)}>♧</button>;
        }
        if (!href) return <span>{children}</span>;
        return (
          <a {...props} href={href} onClick={(event) => {
            event.preventDefault();
            link(href.startsWith("#") ? "anchor" : "external", href.startsWith("#") ? href.slice(1) : href);
          }}>{children}</a>
        );
      },
      span({ children, node, ...props }) {
        return node?.properties.dataSpoiler !== undefined
          ? <Spoiler>{children}</Spoiler>
          : <span {...props}>{children}</span>;
      },
      input({ node, checked, type }) {
        if (type !== "checkbox") return null;
        const location = node?.properties.dataTaskLocation;
        const expectedMarker = node?.properties.dataTaskExpected;
        const replacementMarker = node?.properties.dataTaskReplacement;
        const addressable = typeof location === "number" && typeof expectedMarker === "string" && typeof replacementMarker === "string";
        return (
          <label className="task-toggle"><input type="checkbox" checked={!!checked} disabled={!addressable} aria-label={checked ? "Mark task incomplete" : "Mark task complete"}
            onChange={() => {
              if (!addressable) return;
              send({
                ...identity(request), type: "taskToggle",
                edit: { location, length: 3, expectedMarker, replacementMarker } as TaskEdit,
              });
            }} /></label>
        );
      },
      pre({ children, node, ...props }) {
        const isDiagram = node?.children.some((child) => child.type === "element" &&
          child.tagName === "code" && String(child.properties.className).includes("language-mermaid"));
        return isDiagram ? children : <pre {...props}>{children}</pre>;
      },
      code({ children, className, node: _, ...props }) {
        if (className === "language-mermaid") {
          return <Mermaid content={String(children).trim()} onExpand={() => {}} />;
        }
        if (className === "language-tldraw") {
          return <span className="unsupported">Whiteboards are not supported in GistPad Native.</span>;
        }
        return <code {...props} className={className}>{children}</code>;
      },
      table({ node: _, ...props }) {
        return <div className="table-scroll"><table {...props} /></div>;
      },
      p({ node: _, ...props }) {
        return <p {...props} dir="auto" />;
      },
      img({ src, alt }) {
        return <PreviewImage src={typeof src === "string" ? src : undefined} alt={alt ?? ""} />;
      },
    };
  }, [request]);
  const remarkPlugins: Options["remarkPlugins"] = [
    remarkGfm, remarkGithubAlerts, remarkFrontmatter, taskPlugins.remark,
    [remarkInlineSyntax, { emojis }],
  ];
  const rehypePlugins: Options["rehypePlugins"] = [
    rehypeRaw, [rehypeSanitize, schema], rehypeSlug, rehypeToc, taskPlugins.rehype,
  ];

  useEffect(() => {
    send({ ...identity(request), type: "rendered" });
    const reportHeight = () => send({
      ...identity(request), type: "height",
      height: Math.ceil(document.getElementById("root")!.getBoundingClientRect().height),
    });
    const observer = new ResizeObserver(reportHeight);
    observer.observe(document.getElementById("root")!);
    reportHeight();
    return () => observer.disconnect();
  }, [request]);

  return <article className="prose markdown-container" dir="auto">
    <ReactMarkdown remarkPlugins={remarkPlugins} rehypePlugins={rehypePlugins} components={components}
      urlTransform={(url) => /^(?:https?:|mailto:|#)/i.test(url) || url.startsWith("data:image/png;base64,") ? url : ""}>
      {request.markdown}
    </ReactMarkdown>
  </article>;
}

function PreviewImage({ src, alt }: { src?: string; alt: string }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [src]);
  return src && !failed
    ? <img src={src} alt={alt} loading="lazy" referrerPolicy="no-referrer" onError={() => setFailed(true)} />
    : <span className="image-unavailable" role="img" aria-label={alt || "Image"}>{alt || "Image"} · unavailable offline</span>;
}
