import { useNavigate, useLocation } from 'react-router';
import { useEffect, useState } from 'react';
import { GroupConfiguration } from '../components/GroupConfiguration';
import { BLEDevice, DeviceGroup } from '../types';

export function GroupConfigPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const [devices, setDevices] = useState<BLEDevice[]>([]);

  useEffect(() => {
    const stateDevices = location.state?.devices;
    if (!stateDevices || stateDevices.length === 0) {
      navigate('/');
      return;
    }
    setDevices(stateDevices);
  }, [location.state, navigate]);

  const handleGroupConfigComplete = (group: DeviceGroup) => {
    const updatedDevices = devices.map(d => ({ ...d, groupId: group.id }));
    navigate('/control', {
      state: {
        devices: updatedDevices,
        group: group,
      },
    });
  };

  if (devices.length === 0) {
    return null;
  }

  return (
    <div className="size-full bg-slate-50 flex items-center justify-center p-4">
      <div className="w-full max-w-2xl">
        <GroupConfiguration devices={devices} onComplete={handleGroupConfigComplete} />
      </div>
    </div>
  );
}
