async (page) => {
  await page.addInitScript(() => {
    window.__nativeGeneration = 0;
    window.__nativeSource = "# Queue\n\nA thought.\n";
    window.__nativeMessages = 0;
    window.__nativeErrors = [];
    window.webkit = { messageHandlers: { gistpadDocumint: { postMessage(event) {
      if (event.type !== "changed") return;
      if (event.generation !== String(window.__nativeGeneration)) {
        window.__nativeErrors.push("Two rich edits used the same native generation");
        return;
      }
      window.__nativeMessages += 1;
      setTimeout(() => {
        window.__nativeSource = event.markdown;
        window.gistpadDocumint.acknowledge(event.revision, String(++window.__nativeGeneration));
      }, 75);
    } } } };
  });
  await page.goto("http://127.0.0.1:4181/Web/index.html");
  await page.waitForFunction(() => Boolean(window.gistpadDocumint));
  await page.evaluate(() => window.gistpadDocumint.setDocument({
    documentID: "queue", generation: "0", markdown: window.__nativeSource,
  }));
  await page.waitForFunction(() => window.gistpadDocumint.metrics().openToPaintMS !== null);
  await page.locator(".documint-content-canvas").click({ position: { x: 60, y: 35 } });
  await page.keyboard.press("ControlOrMeta+Home");
  const insertion = "abcdefghijklmnopqrstuvwxyz0123456789";
  await page.keyboard.type(insertion);
  await page.waitForFunction(() => !window.gistpadDocumint.metrics().pending);
  const result = await page.evaluate((insertion) => ({
    finalBytesMatch: window.__nativeSource === window.gistpadDocumint.snapshot().markdown,
    noLostCharacters: window.__nativeSource.includes(insertion),
    changes: window.gistpadDocumint.metrics().changes,
    nativeTransactions: window.__nativeMessages,
    errors: window.__nativeErrors,
  }), insertion);
  if (!result.finalBytesMatch || !result.noLostCharacters || result.errors.length) {
    throw new Error(JSON.stringify(result));
  }
  return result;
}
