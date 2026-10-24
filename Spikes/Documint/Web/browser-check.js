async (page) => {
  const base = "http://127.0.0.1:4181";
  const externalRequests = [];
  await page.route("**/*", (route) => {
    if (route.request().url().startsWith(base) || route.request().url().startsWith("blob:")) {
      return route.continue();
    }
    externalRequests.push(new URL(route.request().url()).protocol);
    return route.abort("internetdisconnected");
  });
  await page.addInitScript(() => {
    window.__richChanges = [];
    let generation = 0;
    window.webkit = { messageHandlers: { gistpadDocumint: { postMessage(event) {
      if (event.type !== "changed") return;
      window.__richChanges.push(event.markdown);
      queueMicrotask(() => window.gistpadDocumint.acknowledge(event.revision, String(++generation)));
    } } } };
  });
  const results = [];
  for (const name of ["manga", "daily", "oss", "parity"]) {
    const response = await page.request.get(`${base}/${name === "parity" ? "parity.md" : `private/${name}.md`}`);
    if (!response.ok()) throw new Error(`Missing local-only ${name} fixture`);
    const markdown = await response.text();
    await page.goto(`${base}/Web/index.html`);
    await page.waitForFunction(() => Boolean(window.gistpadDocumint));
    await page.setViewportSize({ width: 466, height: 678 });
    await page.evaluate(({ name, markdown }) => window.gistpadDocumint.setDocument({
      documentID: name, generation: "0", markdown,
    }), { name, markdown });
    await page.waitForFunction(() => window.gistpadDocumint.metrics().openToPaintMS !== null);
    await page.waitForTimeout(300);
    const idle = await page.evaluate((markdown) => ({
      byteIdentical: window.gistpadDocumint.snapshot().markdown === markdown,
      callbacks: window.__richChanges.length,
      metrics: window.gistpadDocumint.metrics(),
    }), markdown);
    if (!idle.byteIdentical || idle.callbacks !== 0) throw new Error(`Idle open changed ${name}`);
    await page.locator(".documint-content-canvas").click({ position: { x: 40, y: 54 } });
    await page.keyboard.press("ControlOrMeta+Home");
    await page.keyboard.insertText("X");
    await page.waitForFunction(() => window.__richChanges.length > 0);
    await page.waitForFunction(() => !window.gistpadDocumint.metrics().pending);
    const edit = await page.evaluate((source) => {
      const output = window.gistpadDocumint.snapshot().markdown;
      const before = source.split("\n");
      const after = output.split("\n");
      const rows = Array.from({ length: before.length + 1 }, () => new Uint16Array(after.length + 1));
      for (let i = 1; i <= before.length; i++) for (let j = 1; j <= after.length; j++) {
        rows[i][j] = before[i - 1] === after[j - 1]
          ? rows[i - 1][j - 1] + 1 : Math.max(rows[i - 1][j], rows[i][j - 1]);
      }
      const unchanged = rows[before.length][after.length];
      return {
        callbacks: window.__richChanges.length, outputLength: output.length,
        addedLines: after.length - unchanged, removedLines: before.length - unchanged,
        insTagCount: (output.match(/<ins>/g) ?? []).length,
        sourceInsTagCount: (source.match(/<ins>/g) ?? []).length,
        metadataRetained: !source.startsWith("---\n") || output.startsWith("---\n"),
        metrics: window.gistpadDocumint.metrics(),
      };
    }, markdown);
    results.push({ name, idle, edit });
  }
  return { results, blockedExternalRequestCount: externalRequests.length,
    personalContent: "loaded from loopback /tmp only, omitted from results" };
}
