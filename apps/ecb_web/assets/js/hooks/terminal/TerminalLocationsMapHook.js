export const TerminalLocationsMapHook = {
  mounted() {
    // Use global Leaflet from window (from vendor)
    const Leaflet = window.Leaflet;
    if (!Leaflet) {
      console.error("Leaflet.js not loaded");
      return;
    }
    
    // Initialize map based on filtered region or default
    const mapView = this.el.dataset.mapView || 'street';
    const showClusters = this.el.dataset.showClusters === 'true';
    const showHeatmap = this.el.dataset.showHeatmap === 'true';
    
    // Default to UAE center for location page
    const defaultLat = 24.4539;
    const defaultLng = 54.3773;
    const defaultZoom = 7;
    
    this.map = Leaflet.map(this.el).setView([defaultLat, defaultLng], defaultZoom);
    
    // Add different tile layers
    this.tileLayers = {
      street: Leaflet.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; OpenStreetMap contributors'
      }),
      satellite: Leaflet.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', {
        attribution: '&copy; Esri &mdash; Source: Esri, i-cubed, USDA, USGS, AEX, GeoEye, Getmapping, Aerogrid, IGN, IGP, UPR-EGP, and the GIS User Community'
      }),
      terrain: Leaflet.tileLayer('https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; OpenTopoMap (CC-BY-SA)'
      })
    };
    
    // Set initial tile layer
    this.currentTileLayer = this.tileLayers[mapView];
    this.currentTileLayer.addTo(this.map);
    this.currentMapView = mapView;
    
    // Initialize marker clusters group
    this.markersGroup = Leaflet.layerGroup().addTo(this.map);
    this.clusterGroup = null;
    
    // Initialize heatmap layer
    this.heatmapLayer = null;
    
    // Add drawing controls
    this.initializeDrawingControls(Leaflet);
    
    // Load initial device data
    if (this.el.dataset.devices) {
      try {
        const devices = JSON.parse(this.el.dataset.devices);
        this.updateDeviceMarkers(devices, Leaflet, showClusters, showHeatmap);
      } catch (error) {
        console.error("Error parsing device data:", error);
      }
    }
    
    // Listen for updates from LiveView
    this.handleEvent("update_map_devices", (data) => {
      this.updateDeviceMarkers(data.devices, Leaflet, data.showClusters, data.showHeatmap);
    });
    
    this.handleEvent("change_map_view", (data) => {
      this.changeMapView(data.view);
    });
    
    this.handleEvent("toggle_clusters", (data) => {
      this.toggleClusters(data.enabled);
    });
    
    this.handleEvent("toggle_heatmap", (data) => {
      this.toggleHeatmap(data.enabled);
    });
  },
  
  updated() {
    // Handle LiveView updates to the hook
    if (this.el.dataset.devices) {
      try {
        const devices = JSON.parse(this.el.dataset.devices);
        const mapView = this.el.dataset.mapView || 'street';
        const showClusters = this.el.dataset.showClusters === 'true';
        const showHeatmap = this.el.dataset.showHeatmap === 'true';
        
        console.log('Map updated:', { mapView, showClusters, showHeatmap, deviceCount: devices.length });
        
        // Update map view if changed
        if (mapView !== this.currentMapView) {
          this.changeMapView(mapView);
          this.currentMapView = mapView;
        }
        
        // Update markers with new settings
        this.updateDeviceMarkers(devices, window.Leaflet, showClusters, showHeatmap);
      } catch (error) {
        console.error("Error updating map:", error);
      }
    }
  },
  
  initializeDrawingControls(Leaflet) {
    // Add map controls
    this.map.addControl(new Leaflet.Control.Zoom({ position: 'topright' }));
    
    // Add scale control
    Leaflet.control.scale({ position: 'bottomleft' }).addTo(this.map);
    
    // Add custom controls for drawing (simplified version)
    const customControl = Leaflet.Control.extend({
      onAdd: (map) => {
        const container = Leaflet.DomUtil.create('div', 'leaflet-bar leaflet-control leaflet-control-custom');
        container.style.backgroundColor = 'white';
        container.style.padding = '5px';
        container.innerHTML = `
          <button id="draw-rectangle" title="Draw Rectangle" style="margin: 2px; padding: 5px;">📐</button>
          <button id="draw-circle" title="Draw Circle" style="margin: 2px; padding: 5px;">⭕</button>
          <button id="clear-drawings" title="Clear Drawings" style="margin: 2px; padding: 5px;">🗑️</button>
        `;
        
        Leaflet.DomEvent.disableClickPropagation(container);
        return container;
      }
    });
    
    this.map.addControl(new customControl({ position: 'topright' }));
    
    // Initialize drawing layers
    this.drawnItems = Leaflet.layerGroup().addTo(this.map);
  },
  
  updateDeviceMarkers(devices, Leaflet, showClusters = false, showHeatmap = false) {
    console.log('updateDeviceMarkers called with:', { deviceCount: devices.length, showClusters, showHeatmap });
    
    // Clear existing markers
    if (this.markersGroup) {
      this.map.removeLayer(this.markersGroup);
    }
    if (this.clusterGroup) {
      this.map.removeLayer(this.clusterGroup);
    }
    if (this.heatmapLayer) {
      this.map.removeLayer(this.heatmapLayer);
    }
    
    // Always create fresh marker groups
    this.markersGroup = Leaflet.layerGroup();
    this.clusterGroup = null;
    
    if (showClusters && window.L && window.L.markerClusterGroup) {
      // Use marker clustering if available
      this.clusterGroup = window.L.markerClusterGroup({
        chunkedLoading: true,
        spiderfyOnMaxZoom: true,
        showCoverageOnHover: false,
        zoomToBoundsOnClick: true
      });
    } else {
      this.markersGroup = Leaflet.layerGroup();
    }
    
    const heatmapPoints = [];
    
    devices.forEach(device => {
      if (device.lat && device.lng) {
        const lat = parseFloat(device.lat);
        const lng = parseFloat(device.lng);
        
        if (!isNaN(lat) && !isNaN(lng)) {
          // Create different styled markers based on device status
          const markerIcon = this.createCustomMarker(device.status, Leaflet);
          
          const marker = Leaflet.marker([lat, lng], { icon: markerIcon });
          
          // Add detailed popup with device information
          const popupContent = this.createPopupContent(device);
          marker.bindPopup(popupContent, { maxWidth: 300 });
          
          // Add to appropriate layer
          if (this.clusterGroup) {
            this.clusterGroup.addLayer(marker);
          } else {
            this.markersGroup.addLayer(marker);
          }
          
          // Add to heatmap data
          heatmapPoints.push([lat, lng, this.getDeviceIntensity(device)]);
        }
      }
    });
    
    // Add markers to map
    if (this.clusterGroup) {
      this.map.addLayer(this.clusterGroup);
    } else {
      this.map.addLayer(this.markersGroup);
    }
    
    // Add heatmap if enabled
    if (showHeatmap && window.L && window.L.heatLayer && heatmapPoints.length > 0) {
      this.heatmapLayer = window.L.heatLayer(heatmapPoints, {
        radius: 25,
        blur: 15,
        maxZoom: 17,
        gradient: {
          0.2: 'blue',
          0.4: 'cyan',
          0.6: 'lime',
          0.8: 'yellow',
          1.0: 'red'
        }
      });
      this.map.addLayer(this.heatmapLayer);
    }
    
    // Fit map to show all markers if there are any, otherwise keep current view
    const allLayers = this.clusterGroup || this.markersGroup;
    if (allLayers && allLayers.getLayers && allLayers.getLayers().length > 0) {
      try {
        this.map.fitBounds(allLayers.getBounds(), { padding: [20, 20], maxZoom: 15 });
      } catch (error) {
        console.log('Error fitting bounds, keeping current view:', error);
      }
    } else {
      console.log('No devices to display, keeping current map view');
      // Keep the current map view instead of trying to fit empty bounds
    }
  },
  
  createCustomMarker(status, Leaflet) {
    const colors = {
      'online': '#10B981',
      'offline': '#EF4444',
      'maintenance': '#F59E0B',
      'error': '#DC2626',
      'default': '#6B7280'
    };
    
    const color = colors[status] || colors.default;
    
    return Leaflet.divIcon({
      className: 'custom-device-marker',
      html: `
        <div style="
          background-color: ${color};
          width: 12px;
          height: 12px;
          border-radius: 50%;
          border: 2px solid white;
          box-shadow: 0 2px 4px rgba(0,0,0,0.3);
        "></div>
      `,
      iconSize: [16, 16],
      iconAnchor: [8, 8]
    });
  },
  
  createPopupContent(device) {
    const statusColors = {
      'online': 'text-green-600',
      'offline': 'text-red-600',
      'maintenance': 'text-yellow-600',
      'error': 'text-red-600'
    };
    
    const statusColor = statusColors[device.status] || 'text-gray-600';
    
    return `
      <div class="p-3 max-w-sm">
        <div class="flex items-center justify-between mb-2">
          <h4 class="font-semibold text-gray-900">${device.serial_number || 'Unknown'}</h4>
          <span class="px-2 py-1 text-xs rounded-full bg-gray-100 ${statusColor}">${device.status || 'Unknown'}</span>
        </div>
        <div class="space-y-1 text-sm text-gray-600">
          <p><span class="font-medium">Area:</span> ${device.area || 'N/A'}</p>
          <p><span class="font-medium">Vendor:</span> ${device.vendor || 'N/A'}</p>
          <p><span class="font-medium">Model:</span> ${device.model || 'N/A'}</p>
          <p><span class="font-medium">Address:</span> ${device.address || 'N/A'}</p>
          ${device.location_timestamp ? `<p><span class="font-medium">Last Update:</span> ${new Date(device.location_timestamp).toLocaleString()}</p>` : ''}
        </div>
        <div class="mt-3 flex space-x-2">
          <button 
            onclick="window.liveSocket.execJS(this, 'phx-click', 'view_device_details', '${device.id}')"
            class="px-3 py-1 bg-blue-600 text-white text-xs rounded hover:bg-blue-700"
          >
            View Details
          </button>
          <button 
            onclick="window.liveSocket.execJS(this, 'phx-click', 'create_geofence', '${device.id}')"
            class="px-3 py-1 bg-green-600 text-white text-xs rounded hover:bg-green-700"
          >
            Create Geofence
          </button>
        </div>
      </div>
    `;
  },
  
  getDeviceIntensity(device) {
    // Calculate intensity for heatmap based on device activity
    if (device.status === 'online') return 1.0;
    if (device.status === 'maintenance') return 0.7;
    if (device.status === 'offline') return 0.3;
    return 0.1;
  },
  
  changeMapView(view) {
    if (this.currentTileLayer) {
      this.map.removeLayer(this.currentTileLayer);
    }
    
    this.currentTileLayer = this.tileLayers[view] || this.tileLayers.street;
    this.currentTileLayer.addTo(this.map);
  },
  
  toggleClusters(enabled) {
    // Would need to recreate markers with/without clustering
    if (this.el.dataset.devices) {
      const devices = JSON.parse(this.el.dataset.devices);
      this.updateDeviceMarkers(devices, window.Leaflet, enabled, false);
    }
  },
  
  toggleHeatmap(enabled) {
    if (this.heatmapLayer) {
      if (enabled) {
        this.map.addLayer(this.heatmapLayer);
      } else {
        this.map.removeLayer(this.heatmapLayer);
      }
    }
  },
  
  destroyed() {
    if (this.map) {
      this.map.remove();
    }
  }
};

export default TerminalLocationsMapHook;
