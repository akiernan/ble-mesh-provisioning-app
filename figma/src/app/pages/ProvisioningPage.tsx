import { useNavigate, useLocation } from 'react-router';
import { useEffect, useState } from 'react';
import { Provisioning } from '../components/Provisioning';
import { BLEDevice } from '../types';

export function ProvisioningPage() {
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

  const handleProvisioningComplete = () => {
    const updatedDevices = devices.map(d => ({ ...d, provisioned: true }));
    navigate('/key-binding', { state: { devices: updatedDevices } });
  };

  if (devices.length === 0) {
    return null;
  }

  return (
    <div className="size-full bg-slate-50 flex items-center justify-center p-4">
      <div className="w-full max-w-2xl">
        <Provisioning devices={devices} onComplete={handleProvisioningComplete} />
      </div>
    </div>
  );
}
