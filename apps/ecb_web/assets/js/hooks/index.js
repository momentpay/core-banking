import WorkflowBuilder from "./workflow";
import SoftwareAgGridHook from './software/SoftwareAgGridHook'
import TerminalAgGridHook from './terminal/TerminalAgGridHook'
import TerminalDashboardAgGridHook from './terminal/TerminalDashboardAgGridHook'
import UpdateStatsChartHook from './terminal/UpdateStatsChartHook'
import OnlineRateGaugeHook from './terminal/OnlineRateGaugeHook'
import { TerminalLocationMapHook } from './terminal/TerminalLocationMapHook'
import { AnalyticsGeographicMapHook } from './analytics/AnalyticsGeographicMapHook'
import { TerminalLocationsMapHook } from './terminal/TerminalLocationsMapHook'
import { RemoteControlHook, LogViewerHook } from './terminal/RemoteControlHook'

let Hooks = {}

Hooks.Focus = {
  mounted() {
    this.el.focus()
  }
}

// Debug hook for form submissions
Hooks.FormDebug = {
  mounted() {
    this.el.addEventListener('submit', (e) => {
      console.log('Form submission detected:', e.target);
      console.log('Form data:', new FormData(e.target));
      
      // Log all form data
      const formData = new FormData(e.target);
      for (let [key, value] of formData.entries()) {
        console.log(`${key}: ${value}`);
      }
    });
  }
}

Hooks.SoftwareAgGrid = SoftwareAgGridHook
Hooks.WorkflowBuilder = WorkflowBuilder;
Hooks.TerminalAgGridHook = TerminalAgGridHook;
Hooks.TerminalDashboardAgGridHook = TerminalDashboardAgGridHook;
Hooks.UpdateStatsChartHook = UpdateStatsChartHook;
Hooks.OnlineRateGaugeHook = OnlineRateGaugeHook;
Hooks.TerminalLocationMapHook = TerminalLocationMapHook;
Hooks.AnalyticsGeographicMapHook = AnalyticsGeographicMapHook;
Hooks.TerminalLocationsMapHook = TerminalLocationsMapHook;
Hooks.RemoteControl = RemoteControlHook;
Hooks.LogViewer = LogViewerHook;


export {Hooks}
