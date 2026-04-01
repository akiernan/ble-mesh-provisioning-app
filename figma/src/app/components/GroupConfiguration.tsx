import { useState } from 'react';
import { Users, Home, CheckCircle2, Loader2 } from 'lucide-react';
import type { BLEDevice, DeviceGroup } from '../types';

interface GroupConfigurationProps {
  devices: BLEDevice[];
  onComplete: (group: DeviceGroup) => void;
}

export function GroupConfiguration({ devices, onComplete }: GroupConfigurationProps) {
  const [roomName, setRoomName] = useState('Living Room');
  const [isConfiguring, setIsConfiguring] = useState(false);
  const [progress, setProgress] = useState(0);

  const handleCreateGroup = async () => {
    setIsConfiguring(true);

    const steps = 4;
    for (let i = 0; i < steps; i++) {
      setProgress(((i + 1) / steps) * 100);
      await new Promise(resolve => setTimeout(resolve, 600));
    }

    await new Promise(resolve => setTimeout(resolve, 400));

    const group: DeviceGroup = {
      id: 'group-' + Date.now(),
      name: roomName,
      deviceIds: devices.map(d => d.id),
      state: {
        isOn: false,
        lightness: 50,
        colorTemp: 4000,
      },
    };

    onComplete(group);
  };

  const suggestedRooms = ['Living Room', 'Bedroom', 'Kitchen', 'Office', 'Bathroom', 'Hallway'];

  return (
    <div className="bg-white rounded-2xl shadow-lg overflow-hidden min-h-[600px] flex flex-col">
      <div className="flex-1 p-8">
        <div className="max-w-lg mx-auto space-y-8">
          <div className="text-center space-y-3">
            <div className="inline-flex items-center justify-center w-20 h-20 rounded-full bg-gradient-to-br from-emerald-500 to-teal-500 mb-2">
              <Users className="w-10 h-10 text-white" />
            </div>
            <h1 className="text-4xl font-bold text-slate-900">Group Configuration</h1>
            <p className="text-lg text-slate-600">
              Create a group to control all devices together
            </p>
          </div>

          {!isConfiguring ? (
            <div className="space-y-6">
              <div className="bg-slate-50 rounded-xl p-6 border border-slate-200">
                <div className="flex items-center space-x-3 mb-4">
                  <Users className="w-5 h-5 text-slate-600" />
                  <h3 className="font-semibold text-slate-900">Devices in Group</h3>
                </div>
                <div className="space-y-2">
                  {devices.map((device, index) => (
                    <div
                      key={device.id}
                      className="flex items-center justify-between p-3 bg-white rounded-lg border border-slate-200"
                    >
                      <span className="text-slate-700">{device.name}</span>
                      <div className="flex items-center space-x-2 text-xs text-green-600 bg-green-50 px-2 py-1 rounded-full">
                        <CheckCircle2 className="w-3 h-3" />
                        <span>Ready</span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>

              <div>
                <label className="block text-sm font-semibold text-slate-700 mb-3">
                  Room Name
                </label>
                <input
                  type="text"
                  value={roomName}
                  onChange={(e) => setRoomName(e.target.value)}
                  placeholder="Enter room name"
                  className="w-full px-4 py-3 border-2 border-slate-300 rounded-xl focus:border-emerald-500 focus:outline-none text-slate-900 font-medium"
                />
              </div>

              <div>
                <label className="block text-sm font-semibold text-slate-700 mb-3">
                  Quick Select
                </label>
                <div className="grid grid-cols-3 gap-2">
                  {suggestedRooms.map((room) => (
                    <button
                      key={room}
                      onClick={() => setRoomName(room)}
                      className={`p-3 rounded-lg border-2 transition-all ${
                        roomName === room
                          ? 'border-emerald-500 bg-emerald-50 text-emerald-700'
                          : 'border-slate-200 bg-white text-slate-700 hover:border-slate-300'
                      }`}
                    >
                      <Home className="w-4 h-4 mx-auto mb-1" />
                      <div className="text-xs font-medium">{room}</div>
                    </button>
                  ))}
                </div>
              </div>

              <button
                onClick={handleCreateGroup}
                disabled={!roomName.trim()}
                className="w-full py-4 px-6 bg-gradient-to-r from-emerald-600 to-teal-600 text-white rounded-xl hover:from-emerald-700 hover:to-teal-700 transition-all font-semibold text-lg shadow-lg shadow-emerald-500/30 disabled:from-slate-300 disabled:to-slate-300 disabled:shadow-none disabled:cursor-not-allowed"
              >
                Create Group
              </button>
            </div>
          ) : (
            <div className="space-y-6">
              <div className="text-center py-8">
                <Loader2 className="w-12 h-12 text-emerald-600 animate-spin mx-auto mb-4" />
                <p className="text-slate-600 font-medium mb-2">Configuring group bindings...</p>
                <p className="text-sm text-slate-500">Setting up "{roomName}"</p>
              </div>

              <div className="space-y-3">
                <div className="flex justify-between text-sm font-medium text-slate-600">
                  <span>Setup Progress</span>
                  <span>{progress.toFixed(0)}%</span>
                </div>
                <div className="w-full h-3 bg-slate-200 rounded-full overflow-hidden">
                  <div
                    className="h-full bg-gradient-to-r from-emerald-600 to-teal-600 transition-all duration-300"
                    style={{ width: `${progress}%` }}
                  />
                </div>
              </div>

              <div className="space-y-2">
                <div className="flex items-center space-x-2 text-sm text-slate-600">
                  <div className="w-2 h-2 rounded-full bg-emerald-600 animate-pulse" />
                  <span>Assigning group address</span>
                </div>
                <div className="flex items-center space-x-2 text-sm text-slate-600">
                  <div className="w-2 h-2 rounded-full bg-emerald-600 animate-pulse" />
                  <span>Binding devices to group</span>
                </div>
                <div className="flex items-center space-x-2 text-sm text-slate-600">
                  <div className="w-2 h-2 rounded-full bg-emerald-600 animate-pulse" />
                  <span>Configuring publication settings</span>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
