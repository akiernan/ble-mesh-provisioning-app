import { useState } from 'react';
import { Power, Sun, Thermometer, Settings, Lightbulb, RotateCcw } from 'lucide-react';
import type { BLEDevice, DeviceGroup } from '../types';
import * as Slider from '@radix-ui/react-slider';

interface DeviceControlProps {
  group: DeviceGroup;
  devices: BLEDevice[];
  onGroupUpdate: (groupId: string, updates: Partial<DeviceGroup['state']>) => void;
  onRestart: () => void;
}

export function DeviceControl({ group, devices, onGroupUpdate, onRestart }: DeviceControlProps) {
  const [showDevices, setShowDevices] = useState(false);

  const handlePowerToggle = () => {
    onGroupUpdate(group.id, { isOn: !group.state.isOn });
  };

  const handleLightnessChange = (value: number[]) => {
    onGroupUpdate(group.id, { lightness: value[0] });
  };

  const handleColorTempChange = (value: number[]) => {
    onGroupUpdate(group.id, { colorTemp: value[0] });
  };

  const getColorTempGradient = () => {
    return 'linear-gradient(to right, #ff8c42, #ffd700, #ffffff, #b3d9ff, #4a90e2)';
  };

  const getColorTempLabel = (temp: number) => {
    if (temp < 2500) return 'Warm';
    if (temp < 4000) return 'Neutral Warm';
    if (temp < 5500) return 'Neutral';
    if (temp < 7000) return 'Cool';
    return 'Daylight';
  };

  return (
    <div className="bg-white rounded-2xl shadow-lg overflow-hidden">
      <div className="bg-gradient-to-r from-slate-800 to-slate-900 p-6">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            <div className="w-12 h-12 rounded-xl bg-white/10 backdrop-blur-sm flex items-center justify-center">
              <Lightbulb className="w-6 h-6 text-white" />
            </div>
            <div>
              <h1 className="text-2xl font-bold text-white">{group.name}</h1>
              <p className="text-slate-300 text-sm">{devices.length} device{devices.length !== 1 ? 's' : ''}</p>
            </div>
          </div>
          <button
            onClick={onRestart}
            className="p-2.5 rounded-lg bg-white/10 hover:bg-white/20 transition-colors backdrop-blur-sm"
            title="Restart setup"
          >
            <RotateCcw className="w-5 h-5 text-white" />
          </button>
        </div>
      </div>

      <div className="p-8 space-y-8">
        <div>
          <div className="flex items-center justify-between mb-6">
            <h2 className="text-lg font-semibold text-slate-900 flex items-center gap-2">
              <Power className="w-5 h-5" />
              Power
            </h2>
            <button
              onClick={handlePowerToggle}
              className={`relative inline-flex h-10 w-20 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 ${
                group.state.isOn
                  ? 'bg-gradient-to-r from-blue-600 to-cyan-600 focus:ring-blue-500'
                  : 'bg-slate-300 focus:ring-slate-400'
              }`}
            >
              <span
                className={`inline-block h-8 w-8 transform rounded-full bg-white shadow-lg transition-transform ${
                  group.state.isOn ? 'translate-x-11' : 'translate-x-1'
                }`}
              />
            </button>
          </div>

          <div className={`transition-opacity ${group.state.isOn ? 'opacity-100' : 'opacity-40'}`}>
            <div className="bg-slate-50 rounded-xl p-6 space-y-8">
              <div>
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-2">
                    <Sun className="w-5 h-5 text-slate-700" />
                    <h3 className="font-semibold text-slate-900">Brightness</h3>
                  </div>
                  <span className="text-2xl font-bold text-slate-900">{group.state.lightness}%</span>
                </div>
                <Slider.Root
                  className="relative flex items-center select-none touch-none w-full h-6"
                  value={[group.state.lightness]}
                  onValueChange={handleLightnessChange}
                  max={100}
                  step={1}
                  disabled={!group.state.isOn}
                >
                  <Slider.Track className="bg-slate-300 relative grow rounded-full h-3">
                    <Slider.Range className="absolute bg-gradient-to-r from-blue-600 to-cyan-600 rounded-full h-full" />
                  </Slider.Track>
                  <Slider.Thumb
                    className="block w-6 h-6 bg-white shadow-lg rounded-full border-2 border-blue-600 hover:scale-110 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 transition-transform disabled:opacity-50"
                    aria-label="Brightness"
                  />
                </Slider.Root>
                <div className="flex justify-between text-xs text-slate-500 mt-2 px-1">
                  <span>0%</span>
                  <span>50%</span>
                  <span>100%</span>
                </div>
              </div>

              <div>
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-2">
                    <Thermometer className="w-5 h-5 text-slate-700" />
                    <h3 className="font-semibold text-slate-900">Color Temperature</h3>
                  </div>
                  <span className="text-lg font-bold text-slate-900">
                    {group.state.colorTemp}K
                    <span className="text-sm font-normal text-slate-600 ml-2">
                      ({getColorTempLabel(group.state.colorTemp)})
                    </span>
                  </span>
                </div>
                <Slider.Root
                  className="relative flex items-center select-none touch-none w-full h-6"
                  value={[group.state.colorTemp]}
                  onValueChange={handleColorTempChange}
                  min={2000}
                  max={8000}
                  step={100}
                  disabled={!group.state.isOn}
                >
                  <Slider.Track
                    className="relative grow rounded-full h-3"
                    style={{ background: getColorTempGradient() }}
                  >
                    <Slider.Range className="absolute rounded-full h-full opacity-0" />
                  </Slider.Track>
                  <Slider.Thumb
                    className="block w-6 h-6 bg-white shadow-lg rounded-full border-2 border-slate-600 hover:scale-110 focus:outline-none focus:ring-2 focus:ring-slate-500 focus:ring-offset-2 transition-transform disabled:opacity-50"
                    aria-label="Color Temperature"
                  />
                </Slider.Root>
                <div className="flex justify-between text-xs text-slate-500 mt-2 px-1">
                  <span>2000K (Warm)</span>
                  <span>5000K</span>
                  <span>8000K (Cool)</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div>
          <button
            onClick={() => setShowDevices(!showDevices)}
            className="w-full flex items-center justify-between p-4 rounded-xl border-2 border-slate-200 hover:border-slate-300 transition-colors bg-white"
          >
            <div className="flex items-center gap-3">
              <Settings className="w-5 h-5 text-slate-600" />
              <span className="font-semibold text-slate-900">Individual Devices</span>
            </div>
            <svg
              className={`w-5 h-5 text-slate-600 transition-transform ${showDevices ? 'rotate-180' : ''}`}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
            </svg>
          </button>

          {showDevices && (
            <div className="mt-3 space-y-2">
              {devices.map((device) => (
                <div
                  key={device.id}
                  className="p-4 rounded-lg border border-slate-200 bg-slate-50 flex items-center justify-between"
                >
                  <div className="flex items-center gap-3">
                    <div className={`w-3 h-3 rounded-full ${group.state.isOn ? 'bg-green-500' : 'bg-slate-400'}`} />
                    <div>
                      <div className="font-medium text-slate-900">{device.name}</div>
                      <div className="text-xs text-slate-500">ID: {device.id}</div>
                    </div>
                  </div>
                  <div className="flex items-center gap-2 text-xs">
                    <div className="px-2 py-1 rounded-full bg-green-100 text-green-700 font-medium">
                      Connected
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="bg-blue-50 border-2 border-blue-200 rounded-xl p-5">
          <div className="flex items-start gap-3">
            <div className="w-6 h-6 rounded-full bg-blue-600 flex items-center justify-center flex-shrink-0 mt-0.5">
              <span className="text-white text-xs font-bold">i</span>
            </div>
            <div className="text-sm">
              <div className="font-semibold text-blue-900 mb-1">Mesh Network Active</div>
              <div className="text-blue-700 leading-relaxed">
                All devices in this group are connected via BLE mesh. Changes are broadcast to all devices simultaneously for synchronized control.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
