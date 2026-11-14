export const TerminalLocationMapHook = {
  mounted() {
    let lat = parseFloat(this.el.dataset.lat);
    let lng = parseFloat(this.el.dataset.lng);
    // If lat/lng are not valid, default to Bangalore
    if (isNaN(lat) || isNaN(lng)) {
      lat = 12.9716;
      lng = 77.5946;
    }
    // Use global Leaflet from window (from vendor)
    const Leaflet = window.Leaflet;
    if (!Leaflet) {
      console.error("Leaflet.js not loaded");
      return;
    }
    this.map = Leaflet.map(this.el).setView([lat, lng], 15);
    Leaflet.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors'
    }).addTo(this.map);
    Leaflet.marker([lat, lng]).addTo(this.map);
  },
  destroyed() {
    if (this.map) {
      this.map.remove();
    }
  }
};

export default TerminalLocationMapHook;

