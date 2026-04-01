export type BLEDevice = {
  id: string;
  name: string;
  rssi: number;
  provisioned: boolean;
  keysBound: boolean;
  groupId?: string;
};

export type DeviceGroup = {
  id: string;
  name: string;
  deviceIds: string[];
  state: {
    isOn: boolean;
    lightness: number;
    colorTemp: number;
  };
};
