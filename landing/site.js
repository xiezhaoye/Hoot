const preview = document.querySelector("#image-preview");
const previewImage = preview.querySelector("img");
const previewCaption = preview.querySelector("p");
for (const button of document.querySelectorAll("[data-preview]")) {
  button.addEventListener("click", () => {
    previewImage.src = button.dataset.preview;
    previewImage.alt = button.dataset.caption;
    previewCaption.textContent = button.dataset.caption;
    preview.showModal();
  });
}
preview.querySelector(".preview-close").addEventListener("click", () => preview.close());
preview.addEventListener("click", (event) => {
  if (event.target !== preview) return;
  const rect = preview.getBoundingClientRect();
  if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) preview.close();
});
