// Populate the sidebar
//
// This is a script, and not included directly in the page, to control the total size of the book.
// The TOC contains an entry for each page, so if each page includes a copy of the TOC,
// the total size of the page becomes O(n**2).
class MDBookSidebarScrollbox extends HTMLElement {
    constructor() {
        super();
    }
    connectedCallback() {
        this.innerHTML = '<ol class="chapter"><li class="chapter-item expanded "><a href="introduction.html"><strong aria-hidden="true">1.</strong> Introduction</a></li><li class="chapter-item expanded "><a href="overview.html"><strong aria-hidden="true">2.</strong> Overview</a></li><li class="chapter-item expanded affix "><li class="part-title">User guide</li><li class="chapter-item expanded "><a href="connecting.html"><strong aria-hidden="true">3.</strong> Establishing a JSON-RPC connection</a></li><li class="chapter-item expanded "><a href="receiving_requests.html"><strong aria-hidden="true">4.</strong> Receiving a JSON-RPC request</a></li><li class="chapter-item expanded "><a href="sending_requests.html"><strong aria-hidden="true">5.</strong> Sending a JSON-RPC request</a></li><li class="chapter-item expanded "><a href="rpc_proxy_server.html"><strong aria-hidden="true">6.</strong> RPC Proxy Server</a></li><li class="chapter-item expanded "><a href="exceptions.html"><strong aria-hidden="true">7.</strong> Throwing and handling exceptions</a></li><li class="chapter-item expanded "><a href="format_conversion.html"><strong aria-hidden="true">8.</strong> Format conversion</a></li><li class="chapter-item expanded "><a href="testability.html"><strong aria-hidden="true">9.</strong> Testability</a></li><li class="chapter-item expanded "><a href="api_reference.html"><strong aria-hidden="true">10.</strong> API reference</a></li><li class="chapter-item expanded affix "><li class="part-title">Cookbook</li><li class="chapter-item expanded "><a href="cookbook/json_format.html"><strong aria-hidden="true">11.</strong> JSON Format</a></li><li class="chapter-item expanded "><a href="cookbook/http_server.html"><strong aria-hidden="true">12.</strong> HTTP server</a></li><li class="chapter-item expanded "><a href="cookbook/http_client.html"><strong aria-hidden="true">13.</strong> HTTP client</a></li><li class="chapter-item expanded "><a href="cookbook/socket_server.html"><strong aria-hidden="true">14.</strong> Socket server</a></li><li class="chapter-item expanded "><a href="cookbook/socket_client.html"><strong aria-hidden="true">15.</strong> Socket client</a></li><li class="chapter-item expanded "><a href="cookbook/websocket_server.html"><strong aria-hidden="true">16.</strong> Websocket server</a></li><li class="chapter-item expanded "><a href="cookbook/websocket_client.html"><strong aria-hidden="true">17.</strong> Websocket client</a></li><li class="chapter-item expanded "><a href="cookbook/proxy_server.html"><strong aria-hidden="true">18.</strong> Proxy server</a></li><li class="chapter-item expanded "><a href="cookbook/proxy_client.html"><strong aria-hidden="true">19.</strong> Proxy client</a></li><li class="chapter-item expanded affix "><li class="part-title">Developer guide</li><li class="chapter-item expanded "><a href="book.html"><strong aria-hidden="true">20.</strong> Updating this book</a></li></ol>';
        // Set the current, active page, and reveal it if it's hidden
        let current_page = document.location.href.toString().split("#")[0].split("?")[0];
        if (current_page.endsWith("/")) {
            current_page += "index.html";
        }
        var links = Array.prototype.slice.call(this.querySelectorAll("a"));
        var l = links.length;
        for (var i = 0; i < l; ++i) {
            var link = links[i];
            var href = link.getAttribute("href");
            if (href && !href.startsWith("#") && !/^(?:[a-z+]+:)?\/\//.test(href)) {
                link.href = path_to_root + href;
            }
            // The "index" page is supposed to alias the first chapter in the book.
            if (link.href === current_page || (i === 0 && path_to_root === "" && current_page.endsWith("/index.html"))) {
                link.classList.add("active");
                var parent = link.parentElement;
                if (parent && parent.classList.contains("chapter-item")) {
                    parent.classList.add("expanded");
                }
                while (parent) {
                    if (parent.tagName === "LI" && parent.previousElementSibling) {
                        if (parent.previousElementSibling.classList.contains("chapter-item")) {
                            parent.previousElementSibling.classList.add("expanded");
                        }
                    }
                    parent = parent.parentElement;
                }
            }
        }
        // Track and set sidebar scroll position
        this.addEventListener('click', function(e) {
            if (e.target.tagName === 'A') {
                sessionStorage.setItem('sidebar-scroll', this.scrollTop);
            }
        }, { passive: true });
        var sidebarScrollTop = sessionStorage.getItem('sidebar-scroll');
        sessionStorage.removeItem('sidebar-scroll');
        if (sidebarScrollTop) {
            // preserve sidebar scroll position when navigating via links within sidebar
            this.scrollTop = sidebarScrollTop;
        } else {
            // scroll sidebar to current active section when navigating via "next/previous chapter" buttons
            var activeSection = document.querySelector('#sidebar .active');
            if (activeSection) {
                activeSection.scrollIntoView({ block: 'center' });
            }
        }
        // Toggle buttons
        var sidebarAnchorToggles = document.querySelectorAll('#sidebar a.toggle');
        function toggleSection(ev) {
            ev.currentTarget.parentElement.classList.toggle('expanded');
        }
        Array.from(sidebarAnchorToggles).forEach(function (el) {
            el.addEventListener('click', toggleSection);
        });
    }
}
window.customElements.define("mdbook-sidebar-scrollbox", MDBookSidebarScrollbox);
