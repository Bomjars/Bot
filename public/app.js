(() => {
    const input = document.getElementById("search-input");
    const status = document.getElementById("status");
    const results = document.getElementById("results");

    const DEBOUNCE_MS = 250;
    let debounceTimer = null;
    let requestId = 0;

    function clearResults() {
        results.textContent = "";
    }

    function setStatus(message) {
        status.textContent = message;
    }

    function formatPrice(price, currency) {
        const value = Number(price);
        try {
            return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value);
        } catch (err) {
            return `${currency} ${value.toFixed(2)}`;
        }
    }

    function formatDate(isoString) {
        const date = new Date(isoString);
        return Number.isNaN(date.getTime()) ? isoString : date.toLocaleDateString();
    }

    function renderResults(items) {
        clearResults();
        for (const item of items) {
            const li = document.createElement("li");
            li.className = "result-row";

            const price = document.createElement("div");
            price.className = "result-price";
            price.textContent = formatPrice(item.price, item.currency);

            const name = document.createElement("div");
            name.className = "result-name";
            name.textContent = item.name;

            const meta = document.createElement("div");
            meta.className = "result-meta";
            meta.textContent = `SKU: ${item.sku} · Updated: ${formatDate(item.updated_at)}`;

            li.append(price, name, meta);
            results.appendChild(li);
        }
    }

    async function runSearch(query) {
        const currentRequestId = ++requestId;
        setStatus("Searching…");
        clearResults();
        try {
            const response = await fetch(`/api/items/search?q=${encodeURIComponent(query)}`);
            if (currentRequestId !== requestId) return;
            if (!response.ok) throw new Error("Request failed");
            const items = await response.json();
            if (currentRequestId !== requestId) return;
            if (items.length === 0) {
                setStatus(`No items found for "${query}".`);
            } else {
                setStatus(`${items.length} result${items.length === 1 ? "" : "s"} found.`);
                renderResults(items);
            }
        } catch (err) {
            if (currentRequestId !== requestId) return;
            setStatus("Something went wrong. Please try again.");
        }
    }

    input.addEventListener("input", () => {
        const query = input.value.trim();
        clearTimeout(debounceTimer);
        if (!query) {
            requestId++;
            setStatus("");
            clearResults();
            return;
        }
        debounceTimer = setTimeout(() => runSearch(query), DEBOUNCE_MS);
    });
})();
