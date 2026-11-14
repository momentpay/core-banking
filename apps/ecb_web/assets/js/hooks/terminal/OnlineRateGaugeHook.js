const OnlineRateGaugeHook = {
	mounted() {
		const rate = parseFloat(this.el.dataset.rate || '0');
		const options = {
			type: "radial-gauge",
			container: this.el,
			title: { text: "Online Rate" },
			value: rate,
			startAngle: 270,
			endAngle: 540,
			scale: {
				min: 0,
				max: 100,
				interval: { step: 10 },
				fillOpacity: 0.8,
			},
			segmentation: {
				interval: { values: [60, 80] },
			},
			bar: {
				fillOpacity: 0.6,
			},
			innerRadiusRatio: 0.9,
			secondaryLabel: {
				text: "%",
			},
			cornerRadius: 50,
			targets: [
				{
					value: 80,
					shape: "triangle",
					placement: "inside",
					spacing: 5,
					fill: "#8884",
					text: "TARGET",
					label: {
						color: "#8888",
						fontSize: 8,
						fontWeight: "bold",
						spacing: 2,
					},
				},
			],
		};
		this.chart = agCharts.AgCharts.create(options);
	},
	updated() {
		if (this.chart && this.el.dataset.rate) {
			const rate = parseFloat(this.el.dataset.rate || '0');
			this.chart.update({ data: [{ value: rate }] });
		}
	},
	destroyed() {
		if (this.chart) this.chart.destroy();
	}
};

export default OnlineRateGaugeHook;

