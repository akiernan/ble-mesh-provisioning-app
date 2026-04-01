import { useState } from 'react';
import { Bluetooth, Loader2, Radio } from 'lucide-react';
import type { BLEDevice } from '../types';

interface DeviceDiscoveryProps {
  onDevicesDiscovered: (devices: BLEDevice[]) => void;
}

export function DeviceDiscovery({ onDevicesDiscovered }: DeviceDiscoveryProps) {
  const [isScanning, setIsScanning] = useState(false);
  const [discoveredDevices, setDiscoveredDevices] = useState<BLEDevice[]>([]);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());

  const startDiscovery = async () => {
    setIsScanning(true);
    setDiscoveredDevices([]);
    setSelectedIds(new Set());

    await new Promise(resolve => setTimeout(resolve, 800));

    const mockDevices: BLEDevice[] = [
      { id: 'ble-mesh-001', name: 'Mesh Light #1', rssi: -45, provisioned: false, keysBound: false },
      { id: 'ble-mesh-002', name: 'Mesh Light #2', rssi: -52, provisioned: false, keysBound: false },
      { id: 'ble-mesh-003', name: 'Mesh Light #3', rssi: -38, provisioned: false, keysBound: false },
      { id: 'ble-mesh-004', name: 'Mesh Light #4', rssi: -61, provisioned: false, keysBound: false },
    ];

    for (let i = 0; i < mockDevices.length; i++) {
      await new Promise(resolve => setTimeout(resolve, 400));
      setDiscoveredDevices(prev => [...prev, mockDevices[i]]);
      setSelectedIds(prev => new Set([...prev, mockDevices[i].id]));
    }

    setIsScanning(false);
  };

  const toggleDevice = (deviceId: string) => {
    setSelectedIds(prev => {
      const newSet = new Set(prev);
      if (newSet.has(deviceId)) {
        newSet.delete(deviceId);
      } else {
        newSet.add(deviceId);
      }
      return newSet;
    });
  };

  const handleContinue = () => {
    const selected = discoveredDevices.filter(d => selectedIds.has(d.id));
    onDevicesDiscovered(selected);
  };

  const getSignalInfo = (rssi: number) => {
    if (rssi > -50) return { label: 'Excellent', bars: 4, color: 'text-green-600' };
    if (rssi > -60) return { label: 'Good', bars: 3, color: 'text-blue-600' };
    if (rssi > -70) return { label: 'Fair', bars: 2, color: 'text-yellow-600' };
    return { label: 'Weak', bars: 1, color: 'text-red-600' };
  };

  return (
    <div className="bg-white rounded-2xl shadow-lg overflow-hidden min-h-[600px] flex flex-col">
      <div className="flex-1 p-8">
        <div className="max-w-lg mx-auto space-y-8">
          <div className="text-center space-y-3">
            <div className="inline-flex items-center justify-center w-20 h-20 rounded-full bg-gradient-to-br from-blue-500 to-cyan-500 mb-2">
              <Bluetooth className="w-10 h-10 text-white" />
            </div>
            <h1 className="text-4xl font-bold text-slate-900">Discover Devices</h1>
            <p className="text-lg text-slate-600">
              Scan for nearby BLE mesh devices to add to your network
            </p>
          </div>

          {!isScanning && discoveredDevices.length === 0 && (
            <button
              onClick={startDiscovery}
              className="w-full py-4 px-6 bg-gradient-to-r from-blue-600 to-cyan-600 text-white rounded-xl hover:from-blue-700 hover:to-cyan-700 transition-all font-semibold text-lg shadow-lg shadow-blue-500/30"
            >
              Start Scanning
            </button>
          )}

          {isScanning && (
            <div className="flex flex-col items-center justify-center py-12 space-y-4">
              <div className="relative">
                <Loader2 className="w-12 h-12 text-blue-600 animate-spin" />
                <div className="absolute inset-0 flex items-center justify-center">
                  <Radio className="w-6 h-6 text-blue-400" />
                </div>
              </div>
              <p className="text-slate-600 font-medium">Scanning for devices...</p>
            </div>
          )}

          {discoveredDevices.length > 0 && (
            <div className="space-y-4">
              <div className="flex items-center justify-between">
                <h3 className="font-semibold text-slate-700 text-lg">
                  Found {discoveredDevices.length} device{discoveredDevices.length !== 1 ? 's' : ''}
                </h3>
                {!isScanning && (
                  <button
                    onClick={startDiscovery}
                    className="text-sm text-blue-600 hover:text-blue-700 font-medium"
                  >
                    Rescan
                  </button>
                )}
              </div>

              <div className="space-y-3">
                {discoveredDevices.map(device => {
                  const signal = getSignalInfo(device.rssi);
                  const isSelected = selectedIds.has(device.id);

                  return (
                    <button
                      key={device.id}
                      onClick={() => toggleDevice(device.id)}
                      className={`w-full p-5 rounded-xl border-2 transition-all ${
                        isSelected
                          ? 'border-blue-500 bg-blue-50 shadow-md'
                          : 'border-slate-200 bg-white hover:border-slate-300 hover:shadow-sm'
                      }`}
                    >
                      <div className="flex items-center justify-between">
                        <div className="flex items-center space-x-4">
                          <div className={`${signal.color}`}>
                            <Radio className="w-5 h-5" />
                          </div>
                          <div className="text-left">
                            <div className="font-semibold text-slate-900">{device.name}</div>
                            <div className="text-sm text-slate-500 flex items-center gap-2">
                              <span>{signal.label}</span>
                              <span>•</span>
                              <span>{device.rssi} dBm</span>
                            </div>
                          </div>
                        </div>
                        <div className={`w-7 h-7 rounded-full border-2 flex items-center justify-center transition-all ${
                          isSelected
                            ? 'border-blue-600 bg-blue-600'
                            : 'border-slate-300'
                        }`}>
                          {isSelected && (
                            <svg className="w-4 h-4 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={3} d="M5 13l4 4L19 7" />
                            </svg>
                          )}
                        </div>
                      </div>
                    </button>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      </div>

      {discoveredDevices.length > 0 && !isScanning && (
        <div className="border-t border-slate-200 p-6 bg-slate-50">
          <button
            onClick={handleContinue}
            disabled={selectedIds.size === 0}
            className="w-full py-4 px-6 bg-gradient-to-r from-blue-600 to-cyan-600 text-white rounded-xl hover:from-blue-700 hover:to-cyan-700 transition-all font-semibold text-lg shadow-lg shadow-blue-500/30 disabled:from-slate-300 disabled:to-slate-300 disabled:shadow-none disabled:cursor-not-allowed"
          >
            Continue with {selectedIds.size} device{selectedIds.size !== 1 ? 's' : ''}
          </button>
        </div>
      )}
    </div>
  );
}
