const UpdateStatsChartHook = {
  mounted() {
    console.log('UpdateStatsChartHook mounted');
    console.log('Element ID:', this.el.id);
    console.log('Initial dataset:', this.el.dataset);
    this.createChart();
  },
  updated() {
    console.log('UpdateStatsChartHook updated');
    console.log('Updated dataset:', this.el.dataset);
    this.createChart(); // Recreate the chart instead of trying to update
  },
  createChart() {
    // Clear any existing content first
    while (this.el.firstChild) {
      this.el.removeChild(this.el.firstChild);
    }
    
    // Destroy existing chart if it exists
    if (this.chart) {
      console.log('Destroying existing chart');
      try {
        this.chart.destroy();
      } catch (error) {
        console.log('Error destroying chart:', error);
      }
      this.chart = null;
    }
    
    const rawData = this.el.dataset.chartData;
    console.log('Raw chart data from dataset:', rawData);
    
    let chartData;
    try {
      chartData = JSON.parse(rawData || '{}');
    } catch (error) {
      console.error('Error parsing chart data:', error);
      this.showError('Failed to parse chart data');
      return;
    }
    
    console.log('Parsed chart data:', chartData);
    console.log('Chart data type:', typeof chartData);
    console.log('Chart data keys:', Object.keys(chartData));
    
    if (!chartData.data || !Array.isArray(chartData.data) || chartData.data.length === 0) {
      console.log('No valid data available for chart - showing message');
      this.showNoData();
      return;
    }
    
    console.log('Data array length:', chartData.data.length);
    console.log('Sample data point:', chartData.data[0]);
    
    const options = {
      container: this.el,
      data: chartData.data,
      series: [
        {
          type: 'line',
          xKey: 'time',
          yKey: 'ota',
          yName: 'OTA updates',
          stroke: '#60a5fa',
          marker: { fill: '#60a5fa', stroke: '#60a5fa' }
        },
        {
          type: 'line',
          xKey: 'time',
          yKey: 'app',
          yName: 'APP downloads',
          stroke: '#6ee7b7',
          marker: { fill: '#6ee7b7', stroke: '#6ee7b7' }
        }
      ],
      axes: [
        { type: 'category', position: 'bottom', title: { text: 'Time' } },
        { type: 'number', position: 'left', title: { text: 'Count' } }
      ],
      legend: { position: 'bottom' }
    };
    
    console.log('Creating chart with options:', options);
    try {
      this.chart = agCharts.AgCharts.create(options);
      console.log('Chart created successfully:', this.chart);
    } catch (error) {
      console.error('Error creating chart:', error);
      this.showError('Failed to create chart: ' + error.message);
    }
  },
  showNoData() {
    this.el.innerHTML = `
      <div class="h-64 flex items-center justify-center">
        <div class="text-center text-gray-500">
          <div class="text-lg mb-2">📊</div>
          <div>No data available for the selected period</div>
        </div>
      </div>
    `;
  },
  showError(message) {
    this.el.innerHTML = `
      <div class="h-64 flex items-center justify-center">
        <div class="text-center text-red-500">
          <div class="text-lg mb-2">⚠️</div>
          <div>${message}</div>
        </div>
      </div>
    `;
  },
  destroyed() {
    console.log('UpdateStatsChartHook destroyed');
    if (this.chart) {
      try {
        this.chart.destroy();
      } catch (error) {
        console.log('Error destroying chart in cleanup:', error);
      }
      this.chart = null;
    }
  }
};

export default UpdateStatsChartHook;

