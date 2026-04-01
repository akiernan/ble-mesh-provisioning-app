import { useNavigate, useLocation } from 'react-router';
import { useEffect, useState } from 'react';
import { KeyBinding } from '../components/KeyBinding';
import { BLEDevice } from '../types';

export function KeyBindingPage() {
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

  const handleKeyBindingComplete = () => {
    const updatedDevices = devices.map(d => ({ ...d, keysBound: true }));
    navigate('/group-config', { state: { devices: updatedDevices } });
  };

  if (devices.length === 0) {
    return null;
  }

  return (
    <div className="size-full bg-slate-50 flex items-center justify-center p-4">
      <div className="w-full max-w-2xl">
        <KeyBinding devices={devices} onComplete={handleKeyBindingComplete} />
      </div>
    </div>
  );
}
