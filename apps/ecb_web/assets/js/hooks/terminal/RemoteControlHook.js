// Remote Control Hooks for handling file downloads and log scrolling
export const RemoteControlHook = {
  mounted() {
    // Handle file download events
    this.handleEvent("download_file", ({ filename, content, type }) => {
      const blob = new Blob([content], { type: type || 'text/plain' });
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      window.URL.revokeObjectURL(url);
    });
  }
};

export const LogViewerHook = {
  mounted() {
    this.autoScroll = true;
    
    // Auto-scroll to bottom when new logs arrive
    this.scrollToBottom();
    
    // Detect manual scroll up to disable auto-scroll
    this.el.addEventListener('scroll', () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el;
      this.autoScroll = (scrollTop + clientHeight >= scrollHeight - 10);
    });
  },
  
  updated() {
    if (this.autoScroll) {
      this.scrollToBottom();
    }
  },
  
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  }
};