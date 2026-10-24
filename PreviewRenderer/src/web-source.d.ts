declare module "@gistpad/rehype-toc" {
  import type { Root } from "hast";
  const rehypeToc: () => (tree: Root) => void;
  export default rehypeToc;
}
