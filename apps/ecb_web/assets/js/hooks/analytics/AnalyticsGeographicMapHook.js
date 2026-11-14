export const AnalyticsGeographicMapHook = {
  mounted() {
    // Use global Leaflet from window (from vendor)
    const Leaflet = window.Leaflet;
    if (!Leaflet) {
      console.error("Leaflet.js not loaded");
      return;
    }
    
    // Default to India center view for analytics overview
    const defaultLat = 20.5937;
    const defaultLng = 78.9629;
    const defaultZoom = 5;
    
    this.map = Leaflet.map(this.el).setView([defaultLat, defaultLng], defaultZoom);
    
    Leaflet.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors'
    }).addTo(this.map);
    
    // Get device location data from the element's data attributes
    if (this.el.dataset.devices) {
      try {
        const devices = JSON.parse(this.el.dataset.devices);
        this.addDeviceMarkers(devices, Leaflet);
      } catch (error) {
        console.error("Error parsing device data:", error);
      }
    }
    
    // Listen for updates from LiveView
    this.handleEvent("update_map_devices", (data) => {
      this.updateDeviceMarkers(data.devices, Leaflet);
    });
  },
  
  addDeviceMarkers(devices, Leaflet) {
    // Clear existing markers if any
    if (this.markersGroup) {
      this.map.removeLayer(this.markersGroup);
    }
    
    this.markersGroup = Leaflet.layerGroup().addTo(this.map);
    
    devices.forEach(device => {
      if (device.lat && device.lng) {
        const lat = parseFloat(device.lat);
        const lng = parseFloat(device.lng);
        
        if (!isNaN(lat) && !isNaN(lng)) {
          // Create different colored markers based on device status
          const markerColor = device.status === 'online' ? 'green' : 
                             device.status === 'offline' ? 'red' : 'orange';
          
          const marker = Leaflet.circleMarker([lat, lng], {
            radius: 6,
            fillColor: markerColor,
            color: markerColor,
            weight: 2,
            opacity: 0.8,
            fillOpacity: 0.6
          });
          
          // Add popup with device information
          const popupContent = `
            <div class="p-2">
              <h4 class="font-semibold">${device.serial_number || 'Unknown'}</h4>
              <p class="text-sm">Status: <span class="font-medium">${device.status || 'Unknown'}</span></p>
              <p class="text-sm">Area: ${device.area || 'N/A'}</p>
              <p class="text-sm">Vendor: ${device.vendor || 'N/A'}</p>
              <p class="text-sm">Model: ${device.model || 'N/A'}</p>
            </div>
          `;
          
          marker.bindPopup(popupContent);
          this.markersGroup.addLayer(marker);
        }
      }
    });
    
    // Fit map to show all markers if there are any
    if (this.markersGroup.getLayers().length > 0) {
      this.map.fitBounds(this.markersGroup.getBounds(), { padding: [20, 20] });
    }
  },
  
  updateDeviceMarkers(devices, Leaflet) {
    this.addDeviceMarkers(devices, Leaflet);
  },
  
  destroyed() {
    if (this.map) {
      this.map.remove();
    }
  }
};

export default AnalyticsGeographicMapHook;
