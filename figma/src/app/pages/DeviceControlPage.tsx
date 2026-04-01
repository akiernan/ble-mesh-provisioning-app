import { useNavigate, useLocation } from 'react-router';
import { useEffect, useState } from 'react';
import { DeviceControl } from '../components/DeviceControl';
import { BLEDevice, DeviceGroup } from '../types';

export function DeviceControlPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const [devices, setDevices] = useState<BLEDevice[]>([]);
  const [group, setGroup] = useState<DeviceGroup | null>(null);

  useEffect(() => {
    const stateDevices = location.state?.devices;
    const stateGroup = location.state?.group;

    if (!stateDevices || !stateGroup) {
      navigate('/');
      return;
    }

    setDevices(stateDevices);
    setGroup(stateGroup);
  }, [location.state, navigate]);

  const handleGroupUpdate = (groupId: string, updates: Partial<DeviceGroup['state']>) => {
    setGroup(prev => {
      if (!prev || prev.id !== groupId) return prev;
      return { ...prev, state: { ...prev.state, ...updates } };
    });
  };

  const handleRestart = () => {
    navigate('/');
  };

  if (!group) {
    return null;
  }

  return (
    <div className="size-full bg-slate-50 flex items-center justify-center p-4">
      <div className="w-full max-w-2xl">
        <DeviceControl
          group={group}
          devices={devices}
          onGroupUpdate={handleGroupUpdate}
          onRestart={handleRestart}
        />
      </div>
    </div>
  );
}
