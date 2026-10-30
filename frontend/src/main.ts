import { mount } from "svelte";
import App from "./App.svelte";
import "./style.css";
mount(App, { target: document.getElementById("app")! });
if ("serviceWorker" in navigator)
  window.addEventListener("load", () =>
    navigator.serviceWorker.register("/sw.js").catch(() => {}),
  );
