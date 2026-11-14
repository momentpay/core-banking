import BaseAgGridHook from '../base/BaseAgGridHook';
const TerminalAgGridHook = {
  mounted() {
    console.log('TerminalAgGridHook mounted');
    const gridContainer = this.el;
    // Use initial rows only for first mount, but always update from LiveView events
    let rows = JSON.parse(gridContainer.dataset.rows || '[]');
    console.log('Initial rows loaded:', rows.length);    // Add click handler for debugging tab clicks
    document.addEventListener('click', (e) => {
      if (e.target.closest('[data-status]')) {
        const status = e.target.closest('[data-status]').dataset.status;
        console.log('Tab clicked:', status);
      }
    });
    // Define columns to match the table in index.html.heex
    const cols = [
      { headerName: 'Serial Number', field: 'serial_number' },
      { headerName: 'OID', field: 'oid' },
      { headerName: 'Status', field: 'status', cellRenderer: params => {
        if (!params.value) return '';
        const val = params.value.toLowerCase();
        const color = val === 'online' ? 'green' : 'red';
        return `<span style="color:${color};font-weight:bold;">${params.value}</span>`;
      } },
      { headerName: "Model", field: "model" },
      { headerName: "Vendor", field: "vendor" },
      { headerName: "IMEI", field: "imei" },
      { headerName: "App Version", field: "app_version" },
      { headerName: "Firmware Version", field: "firmware_version" },
      { headerName: "Last Seen", field: "last_seen_at" },
      { headerName: 'Last Seen', field: 'last_seen_at' },
      { headerName: 'Battery', field: 'battery' },
      { headerName: 'CPU', field: 'cpu' },
      { headerName: 'Memory', field: 'memory' }
    ];
    const rowClickEvent = gridContainer.dataset.rowClickEvent;

    // Add custom cell renderer for status (from DB)
    cols.forEach(col => {
      if (col.field === 'status') {
        col.cellRenderer = params => {
          if (!params.value) return '';
          const val = params.value.toLowerCase();
	  const color = (val === 'connected' || val === 'online') ? 'green' : 'red';
		//const color = val === 'connected' ? 'green' : 'red';
          return `<span style="color:${color};font-weight:bold;">${params.value}</span>`;
        };
      }
    });


   // Add custom cell renderer for status
    cols.forEach(col => {
      if (col.field === 'last_status') {
        col.cellRenderer = params => {
                console.log(params);
          if (!params.value) return '';
          const val = params.value;
          const color = val == "1" ? 'green' : 'red';
          return `<span style="color:${color};font-weight:bold;">${params.value}</span>`;
        };
      }
    });



    // Add sparkline columns for battery, cpu, memory, etc.
    ['battery', 'cpu', 'memory'].forEach(metric => {
      if (!cols.find(c => c.field === metric)) {
        cols.push({
          headerName: metric.charAt(0).toUpperCase() + metric.slice(1),
          field: metric,
          cellRenderer: params => {
            if (!params.value) return '';
            // For now, just show the latest value
            return `<span>${Array.isArray(params.value) ? params.value.slice(-1)[0] : params.value}</span>`;
          }
        });
      }
    });

    // AG Grid setup
    const gridOptions = {
      columnDefs: cols,
      rowData: rows,
      onRowClicked: event => {
        if (rowClickEvent) {
          this.pushEvent(rowClickEvent, {serial_number: event.data.serial_number});
        }
      },
      domLayout: 'autoHeight',
      defaultColDef: {
        resizable: true,
        sortable: true,
        filter: true
      },
      animateRows: true
    };

    // AG Grid initialization (vanilla JS, new API)
    if (window.agGrid && window.agGrid.createGrid) {
      this.gridApi = window.agGrid.createGrid(gridContainer, gridOptions);
      this.gridOptions = gridOptions;
      console.log('AG Grid initialized successfully');
    } else {
      console.error('AG Grid not available. window.agGrid:', window.agGrid);
    }

    // Ensure grid is ready before handling events
    const ensureGridReady = (callback) => {
      if (this.gridApi) {
        callback();
      } else {
        console.warn('Grid not ready, retrying in 100ms...');
        setTimeout(() => ensureGridReady(callback), 100);
      }
    };

    // Listen for LiveView updates
    this.handleEvent('update_terminal_metrics', payload => {
      const opts = this.gridOptions || gridOptions;
      const api = this.gridApi;
      const idx = opts.rowData.findIndex(r => r.serial_number === payload.serial_number);
      if (idx !== -1) {
        Object.assign(opts.rowData[idx], payload.metrics);
        if (api && api.applyTransaction) {
          api.applyTransaction({ update: [opts.rowData[idx]] });
        } else if (api && api.setRowData) {
          api.setRowData(opts.rowData);
        }
      }
    });

    // Listen for LiveView updates for a single row
    this.handleEvent('update_terminal_row', payload => {
      if (!payload || !payload.row) return;
      const api = this.gridApi;
      let found = false;
      api.forEachNode(node => {
        if (node.data.serial_number === payload.row.serial_number) {
          Object.assign(node.data, payload.row);
          found = true;
        }
      });
      if (!found) {
        // If not found, add as new row
        api.applyTransaction({ add: [payload.row] });
      } else {
        api.refreshCells({ force: true });
      }
    });

    // Listen for LiveView updates for entire data set (for filtering)
    this.handleEvent('update_terminals_data', payload => {
      if (!payload || !Array.isArray(payload.rows)) {
        console.error('Invalid payload received:', payload);
        return;
      }
      
      ensureGridReady(() => {
        const api = this.gridApi;
        const opts = this.gridOptions || gridOptions;
        // Always use the latest rows from LiveView, never fallback to initial data
        rows = payload.rows;
        opts.rowData = rows;
        try {
          let updated = false;
          if (api && api.setGridOption) {
            api.setGridOption('rowData', rows);
            updated = true;
          } else if (api && api.setRowData) {
            api.setRowData(rows);
            updated = true;
          } else if (api && api.api && api.api.setRowData) {
            api.api.setRowData(rows);
            updated = true;
          }
          if (updated) {
            setTimeout(() => {
              try {
                if (api.refreshCells) api.refreshCells({ force: true });
                if (api.sizeColumnsToFit) api.sizeColumnsToFit();
              } catch (e) {
                console.warn('Grid refresh error:', e);
              }
            }, 50);
          } else {
            console.error('No suitable update method found. Available methods:', Object.keys(api || {}));
          }
        } catch (error) {
          console.error('Error updating grid data:', error);
          console.error('Available API methods:', api ? Object.keys(api) : 'No API');
          console.log('Attempting grid recreation...');
          try {
            if (this.gridApi && this.gridApi.destroy) {
              this.gridApi.destroy();
            }
            const newGridOptions = { ...gridOptions, rowData: rows };
            this.gridApi = window.agGrid.createGrid(gridContainer, newGridOptions);
            this.gridOptions = newGridOptions;
            console.log('Grid recreated successfully');
          } catch (recreateError) {
            console.error('Grid recreation failed:', recreateError);
          }
        }
      });
    });

    // Listen for new terminal additions
    this.handleEvent('add_terminal_row', payload => {
      if (!payload || !payload.row) return;
      const api = this.gridApi;
      const opts = this.gridOptions || gridOptions;
      
      // Add to row data
      opts.rowData.push(payload.row);
      
      // Add to grid
      if (api && api.applyTransaction) {
        api.applyTransaction({ add: [payload.row] });
      }
    });
  }
};

export default TerminalAgGridHook;

