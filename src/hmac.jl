using HMAC
#TODO: use less allocations

hmacstate = HMAC.HMACState[]

function hmac(s1,s2,s3,s4)
    if isempty(hmacstate)
        return ""
    else
        HMAC.update!(hmacstate[1], s1*s2*s3*s4)
        return HMAC.hexdigest!(hmacstate[1])
    end
end
