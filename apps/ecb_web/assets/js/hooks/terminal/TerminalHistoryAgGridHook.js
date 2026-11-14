import BaseAgGridHook from '../base/BaseAgGridHook';

const TerminalHistoryAgGridHook = {
  mounted() {
    const gridContainer = this.el;
    const rows = JSON.parse(gridContainer.dataset.rows || '[]');
    // Define columns for terminal history
    const cols = [
      { headerName: 'IMEI', field: 'imei' },
      { headerName: 'App Version', field: 'app_version' },
      { headerName: 'Data Version', field: 'data_version' },
      { headerName: 'System Version', field: 'system_version' },
      { headerName: 'Secure Firmware', field: 'secure_firmware' },
      { headerName: 'Boot Version', field: 'boot_version' },
      { headerName: 'Pubkey', field: 'pubkey' },
      { headerName: 'Appkey', field: 'appkey' },
      { headerName: 'Battery', field: 'battery' },
      { headerName: 'IP', field: 'ip' },
      { headerName: 'Area', field: 'area' },
      { headerName: 'Login Time', field: 'login_time' }
    ];

    const gridOptions = {
      columnDefs: cols,
      rowData: rows,
      domLayout: 'autoHeight',
      defaultColDef: {
        resizable: true,
        sortable: true,
        filter: true
      },
      animateRows: true
    };

    if (window.agGrid && window.agGrid.createGrid) {
      this.gridApi = window.agGrid.createGrid(gridContainer, gridOptions);
      this.gridOptions = gridOptions;
    }

    // Listen for LiveView updates (if needed in the future)
    this.handleEvent && this.handleEvent('update_terminal_history_row', payload => {
      if (!payload || !payload.row) return;
      const api = this.gridApi;
      let found = false;
      api.forEachNode(node => {
        if (node.data.imei === payload.row.imei && node.data.login_time === payload.row.login_time) {
          Object.assign(node.data, payload.row);
          found = true;
        }
      });
      if (!found) {
        api.applyTransaction({ add: [payload.row] });
      } else {
        api.refreshCells({ force: true });
      }
    });
  }
};
export default TerminalHistoryAgGridHook;
