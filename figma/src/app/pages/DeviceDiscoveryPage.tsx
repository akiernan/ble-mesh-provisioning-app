import { useNavigate } from 'react-router';
import { DeviceDiscovery } from '../components/DeviceDiscovery';
import { BLEDevice } from '../types';

export function DeviceDiscoveryPage() {
  const navigate = useNavigate();

  const handleDevicesDiscovered = (discoveredDevices: BLEDevice[]) => {
    navigate('/provisioning', { state: { devices: discoveredDevices } });
  };

  return (
    <div className="size-full bg-slate-50 flex items-center justify-center p-4">
      <div className="w-full max-w-2xl">
        <DeviceDiscovery onDevicesDiscovered={handleDevicesDiscovered} />
      </div>
    </div>
  );
}
