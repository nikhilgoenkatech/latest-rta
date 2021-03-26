import boto3

def fetch_dns_ec2_instance(data):
    AWS_REGION = us-east-2
    # Load client
    ec2 = boto3.resource('ec2', region_name=AWS_REGION)

    # Load ec2 instance
    instanceId = data['instanceId']
    instance = ec2.Instance(instanceId)
    try:
        instance.public_dns_name
    except Exception as e:
        if 'InvalidInstanceID.NotFound' in e.response['Error']['Code']:
            try:
                time.sleep(2)
                instance = ec2.Instance(instanceId)
                instance.public_dns_name
            except Exception as e2:
                if "does not exist" in e2.message:
                    return False

    # Just check if the public DNS/IP is there.
    if instance.public_dns_name:
        data[key_publicDnsName] = instance.public_dns_name
        data[key_publicIpAddress] = instance.public_ip_address
        data[key_nipioDomain] = getNipIoDomain(str(instance.public_ip_address))

        print(data[key_email] + ': InstanceId: ' +
                     instanceId + ' :' + instance.public_dns_name)
        return True
    elif instance.state['Name'] == 'running':
        print(action + ':\t' + data[key_email] + ': InstanceId: ' + instanceId +
                        ' : public IP not assigned and the machine is already running. Check your ec2 config')
        return False

    elif instance.state['Name'] == 'pending':
        print(action + ':\t' + data[key_email] +
                     ': waiting until the instance is running to get the public ip ' + instanceId)

        """ Since we are impatient and we know that the dns and IP are long bofore the
        running state assigned, we try to fetch them before the running state.
        """
        while instance.state['Name'] == 'pending':
            instance.reload()
            if instance.public_dns_name:
                data[key_publicDnsName] = instance.public_dns_name
                data[key_publicIpAddress] = instance.public_ip_address
                data[key_nipioDomain] = getNipIoDomain(
                    str(instance.public_ip_address))
                print(
                    action + ':\t' + data[key_email] + ': InstanceId: ' + instanceId + ' : ' + instance.public_dns_name)
                return True
            else:
                print(
                    action + ':\t' + data[key_email] + ': sleeping two seconds to fetch again: ' + instanceId)
                time.sleep(2)

        # This check if it enters running state and we did not check before
        if instance.public_dns_name:
            data[key_publicDnsName] = instance.public_dns_name
            data[key_publicIpAddress] = instance.public_ip_address
            data[key_nipioDomain] = getNipIoDomain(
                str(instance.public_ip_address))
            print(action + ':\t' + data[key_email] + ': Running InstanceId:' +
                         instanceId + ' : ' + instance.public_dns_name)
            return True
        else:
            print(action + ':\t' + data[key_email] + ': InstanceId:' + instanceId +
                            ': public IP not assigned and the machine is already running. Check your ec2 config')
            return False
    else:
        print(action + ':\t' + data[key_email] + ': InstanceId:' + instanceId +
                        ': the instance is not in a correct state. Stopped or terminated?')
        return False

    return False

if __name__ == "__main__":
    for id in CSV_DATA:
       data = CSV_DATA[id]
       fetch_dns_ec2_instance
